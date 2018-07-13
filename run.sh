$ cat run.sh
#!/bin/bash
set -x
set -e

# PREREQS:
# - A replication subnet group must already exist in DMS specifying the vpc and subnets. Have the name of the replication subnet group declared in a variable below
# - A security group for the VPC must already exist in DMS which can be bound to the replication instance. Have the ID of the security group declared in a variable below
# - no replication instance, task, nor endpoint must pre-exist in AWS else we get an error when trying to create them

# the replication instance name (returns an error if you try to create one which already exists)
replicationinstanceid=rep2
sourcebucketname=abilitynetwork.dpl.temp.vantage.csv.upload
targetdatabaseservername=vantage-test.clsgfyazhzak.us-east-1.rds.amazonaws.com
replicationinstancesecuritygroupid=sg-a1a7c8ea
replicationsubnetgroupname=dpl-vantage

# create the new replication instance (note the specs)
aws dms create-replication-instance \
--replication-instance-identifier ${replicationinstanceid} \
--replication-instance-class dms.t2.small \
--allocated-storage 50 \
--availability-zone us-east-1c \
--region us-east-1 \
--no-publicly-accessible \
--vpc-security-group-ids ${replicationinstancesecuritygroupid} \
--replication-subnet-group-identifier ${replicationsubnetgroupname}

# echo out the new replication instance
aws dms describe-replication-instances --filter=Name=replication-instance-id,Values=${replicationinstanceid}

# gather the new replication instance ARN
replicationinstancearn=$(aws dms describe-replication-instances --filter=Name=replication-instance-id,Values=$replicationinstanceid --query 'ReplicationInstances[0].ReplicationInstanceArn' | tr -d '"')

# table names
tablename=claimheader

# create dms source/target endpoints
sourceendpointname=${tablename}-source-endpoint
targetendpointname=${tablename}-target-endpoint

# read the table def from json, escape it and flatten to a one line string
# https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Source.S3.html#CHAP_Source.S3.ExternalTableDef
sourcetabledef=$(cat ${tablename}_tabledef.json | sed -e 's/"/\\"/g' | tr -d '\n')
aws dms create-endpoint \
--endpoint-identifier ${sourceendpointname} \
--endpoint-type source \
--engine-name s3 \
--s3-settings '{ "ServiceAccessRoleArn": "arn:aws:iam::063237965118:role/S3-RDS-DMS-Role", "ExternalTableDefinition": "'"${sourcetabledef}"'", "BucketName": "'"${sourcebucketname}"'" }'

# destination endpoint
aws dms create-endpoint \
--endpoint-identifier $targetendpointname \
--endpoint-type target \
--engine-name postgres \
--database-name vantage_test \
--ssl-mode verify-full \
--certificate-arn arn:aws:dms:us-east-1:063237965118:cert:GL4YXMESKZTBQREJ27Z4X4MB3E \
--username sa \
--password $dbpassword \
--server-name $targetdatabaseservername \
--port 5432

# gather the source endpoint ARNs
sourceendpointarn=$(aws dms describe-endpoints --filter=Name=endpoint-id,Values=${sourceendpointname} --query="Endpoints[0].EndpointArn" | tr -d '"')
targetendpointarn=$(aws dms describe-endpoints --filter=Name=endpoint-id,Values=${targetendpointname} --query="Endpoints[0].EndpointArn" | tr -d '"')

# test the connections to these endpoints... only will work once replicationinstance is created and online
i=1
while [ "$i" -ne 0 ]
do
    i=$(aws dms test-connection --replication-instance-arn $replicationinstancearn --endpoint-arn $sourceendpointarn)
    sleep 5
done
i=1
while [ "$i" -ne 0 ]
do
    i=$(aws dms test-connection --replication-instance-arn $replicationinstancearn --endpoint-arn $targetendpointarn )
    sleep 5
done

# the describe-connections response will contain the status of a connection and details around failures if any
aws dms describe-connections --filter "Name=endpoint-arn,Values=$sourceendpointarn,$targetendpointarn"

# create the replication task which puts source, target and instance together
# replication task settings:
# - TargetMetadata:
#    - TargetSchema: The target table schema name. For our purposes required.
#    - LOB Settings: Settings that drive how large objects LOBs are handled. For our purposes we disable it.
#    - LoadMaxFileSize: An option for PostgreSQL target endpoints that defines the maximum size on disk of stored,
#      unloaded data, such as .csv files. This option overrides the connection attribute. You can provide values from 0,
#      which indicates that this option doesn't override the connection attribute, to 100,000 KB
#    - BatchApplyEnabled: Determines if each transaction is applied individually or if changes are committed in batches.
#      The default value is false. If set to true, AWS DMS commits changes in batches by a pre-processing action that
#      groups the transactions into batches in the most efficient way. Setting this value to true can affect transactional
#      integrity, so you must select BatchApplyPreserveTransaction in the ChangeProcessingTuning section to specify how the
#      system handles referential integrity issues.
#      If set to false, AWS DMS applies each transaction individually, in the order it is committed. In this case, strict
#      referential integrity is ensured for all tables.
#    - ParallelLoadThreads: Specifies the number of threads AWS DMS uses to load each table into the target database
# - FullLoadSettings: To indicate how to handle loading the target at full-load startup, specify one of the following values
#   for the TargetTablePrepMode option:
#    - DO_NOTHING – Data and metadata of the existing target table are not affected.
#    - DROP_AND_CREATE – The existing table is dropped and a new table is created in its place.
#    - TRUNCATE_BEFORE_LOAD – Data is truncated without affecting the table metadata.
# - Logging
#    - EnableLogging: true/false sends replication logging to cloudwatch
#    - Customizing logging: see https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Tasks.CustomizingTasks.TaskSettings.Logging.html
# - ValidationSettings
#    - EnableValidation: true/false to ensure data was accurrately migrated. When enabled DMS compares source and destination after full load complete.
#    - ThreadCount: control parallel processing amount dedicated to post-load validation
replicationtaskname=${tablename}-task
aws dms create-replication-task \
--replication-task-identifier $replicationtaskname \
--source-endpoint-arn $sourceendpointarn \
--target-endpoint-arn $targetendpointarn \
--replication-instance-arn $replicationinstancearn \
--migration-type full-load \
--table-mappings '{ "rules": [ { "rule-type": "selection", "rule-id": "1", "rule-name": "1", "object-locator": { "schema-name": "vantage", "table-name": "'"${tablename}"'" }, "rule-action": "include" } ] }' \
--replication-task-settings '{ "TargetMetadata": { "TargetSchema": "", "SupportLobs": false, "FullLobMode": false }, "FullLoadSettings": { "FullLoadEnabled": true, "ApplyChangesEnabled": false, "TargetTablePrepMode": "DO_NOTHING", "ResumeEnabled": true, "ResumeMinTableSize": 100000}, "Logging":{ "EnableLogging": true } }'


# describe the replication task, make sure it is ready to be executed
aws dms describe-replication-tasks --filter=Name=replication-task-id,Values=${replicationtaskname}

# gather the replication task ARN
replicationtaskarn=$(aws dms describe-replication-tasks --filter=Name=replication-task-id,Values=${replicationtaskname} --query "ReplicationTasks[0].ReplicationTaskArn" | tr -d '"')

# start the replication task
i=1
while [ "$i" -ne 0 ]
do
    i=$(aws dms start-replication-task --replication-task-arn $replicationtaskarn --start-replication-task-type start-replication)
    sleep 5
done

# monitor the replication task
aws dms describe-replication-tasks --filter=Name=replication-task-arn,Values=$replicationtaskarn --query "ReplicationTasks[0].ReplicationTaskStats"

# monitor the replication task from table statistics
aws dms describe-table-statistics --replication-task-arn $replicationtaskarn

# monitor overall task status
aws dms describe-replication-tasks --filter=Name=replication-task-arn,Values=$replicationtaskarn --query "ReplicationTasks[0].{Status:Status,StopReason:StopReason}"

# stop the replication task
aws dms stop-replication-task --replication-task-arn $replicationtaskarn

# delete the replication task
aws dms delete-replication-task --replication-task-arn $replicationtaskarn

# delete source and target endpoints
i=1
while [ "$i" -ne 0 ]
do
    i=$(aws dms delete-endpoint --endpoint-arn $sourceendpointarn)
    sleep 5
done
i=1
while [ "$i" -ne 0 ]
do
  i=$(aws dms delete-endpoint --endpoint-arn $targetendpointarn)
    sleep 5
done

# delete the replication instance
aws dms delete-replication-instance --replication-instance-arn $replicationinstancearn

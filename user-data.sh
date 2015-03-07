#!/bin/bash

#
# Config
#
export QUEUE_URL="https://sqs.us-east-1.amazonaws.com/164773542935/rtward-hashcat"
export S3_BUCKET='rtward-hashcat'
export AWS_DEFAULT_REGION='us-east-1'
export S3_HASH_FILE="s3://$S3_BUCKET/hashes"
export S3_RESULTS_FILE="s3://$S3_BUCKET/`hostname`.results"
export S3_LOG_FILE="s3://$S3_BUCKET/`hostname`.log"


#
# Install Dependencies
#
yum-config-manager --enable epel
yum install -y aws-cli p7zip jq


#
# Download Hashcat
#
if [ ! -e 'cudaHashcat-1.31.7z' ]; then
    HASHCAT_URL="http://hashcat.net/files_legacy/cudaHashcat-1.31.7z"
    wget --read-timeout 10 $HASHCAT_URL
    7za x cudaHashcat-1.31.7z
fi


#
# Download Hashes from S3
#
echo "Fetching hashes to crack from $S3_HASH_FILE"
aws s3 cp $S3_HASH_FILE ./hashes


#
# Setup commands
#
RECEIVE_COMMAND="aws sqs receive-message --queue-url "$QUEUE_URL""
DELETE_COMMAND="aws sqs delete-message --queue-url "$QUEUE_URL" --receipt-handle"
HASHCAT_COMMAND="./cudaHashcat-1.31/cudaHashcat64.bin --potfile-disable --logfile-disable --outfile hashcat.result hashes"


#
# Process Loop
#
TASK_RUN=1
FIRST_RUN=1
while [ $TASK_RUN  -eq 1 ]; do
    TASK_RUN=0

    MESSAGE=`$RECEIVE_COMMAND`

    if [ -n "$MESSAGE" ]; then
        RECEIPT_HANDLE=`echo "$MESSAGE" | jq -r '.Messages[0].ReceiptHandle'`
        TASK=`echo "$MESSAGE" | jq -r '.Messages[0].Body'`

        $DELETE_COMMAND $RECEIPT_HANDLE

        echo "###"
        echo "Running: $HASHCAT_COMMAND $TASK"
        echo "###"
        echo

        if [ $FIRST_RUN -eq 1 ]; then
            echo YES | $HASHCAT_COMMAND $TASK
        else
            $HASHCAT_COMMAND $TASK
        fi

        echo
        echo "###"
        echo "Task Finished"
        echo "###"

        TASK_RUN=1
    else
        echo "No tasks left"
    fi
done


#
# Upload results to s3
#
echo "Uploading results to  $S3_RESULTS_FILE"
aws s3 cp hashcat.result $S3_RESULTS_FILE

echo "Uploading log to $S3_LOG_FILE"
aws s3 cp /var/log/cloud-init-output.log $S3_LOG_FILE


#
# Shutdown
#
shutdown +1


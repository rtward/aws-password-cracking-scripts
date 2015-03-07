#!/bin/bash

HASHCAT=$1
HASHES=$2
FILE_TYPE=$3
PATTERN=$4
PARTITIONS=$5
SERVERS=$6
S3_BUCKET=$7
QUEUE_URL=$8

if [ -z "$HASHCAT" ]; then
    "No hashcat binary specified"
    exit
fi

if [ -z "$HASHES" ]; then
    "No hash file specified"
    exit
fi

if [ -z "$FILE_TYPE" ]; then
    "No file type specified"
    exit
fi

if [ -z "$PATTERN" ]; then
    "No pattern specified"
    exit
fi

if [ -z "$PARTITIONS" ]; then
    PARTITIONS=100
fi

if [ -z "$SERVERS" ]; then
    SERVERS=10;
fi

echo "Uploading hashes file"
aws s3 cp "$HASHES" s3://$S3_BUCKET/hashes
echo "Done"

echo "Finding Keyspace"
KEYSPACE=`$HASHCAT $HASHES -m $FILE_TYPE -a 3 $PATTERN --keyspace | tail -n1`
echo "Got $KEYSPACE"

echo "Finding Partition Size"
PARTITION_SIZE=$(( $KEYSPACE / $PARTITIONS ))
echo "Got $PARTITION_SIZE"


for i in `seq 0 $PARTITIONS`; do
    START=$(( $i * $PARTITION_SIZE ))

    if [ $i -eq $PARTITIONS ]; then
        END=$KEYSPACE
    else
        END=$(( $START + $PARTITION_SIZE ))
    fi

    echo "Partition $i"
    echo "From: $START"
    echo "To:   $END"

    COMMAND="-m $FILE_TYPE -a 3 -s $START -l $PARTITION_SIZE $PATTERN"
    echo "Command: $COMMAND"

    aws sqs send-message \
        --queue-url "$QUEUE_URL" \
        --message-body "$COMMAND"
done

for i in `seq 1 $SERVERS`; do
    aws ec2 run-instances \
        --image-id ami-7200461a \
        --instance-type g2.2xlarge \
        --security-group-ids sg-c5d901a8 \
        --key-name aws-personal \
        --instance-initiated-shutdown-behavior terminate \
        --iam-instance-profile Name=hashcat-server \
        --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"DeleteOnTermination\":true,\"VolumeSize\":32,\"VolumeType\":\"standard\"}}]" \
        --user-data "`cat user-data.sh`"
done

MESSAGES=1
while [ $MESSAGES -gt 0 ]; do
    MESSAGES=`aws sqs get-queue-attributes --queue-url $QUEUE_URL --attribute-names All | jq -r '.Attributes.ApproximateNumberOfMessages'`
    echo "Waiting for all messages to finish processing, $MESSAGES left"
    sleep 60
done

echo "All messages processed, waiting an additional two minutes for all instances to finish"
sleep 120

echo "Downloading results"
mkdir -p results
aws s3 cp --recursive s3://$S3_BUCKET/* ./results/
echo "Done"


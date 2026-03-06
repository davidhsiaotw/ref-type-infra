#!/bin/bash
aws ec2 terminate-instances --instance-ids $INSTANCE_ID
echo "Instance $INSTANCE_ID terminated."

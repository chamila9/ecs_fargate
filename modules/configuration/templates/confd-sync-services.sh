#!/bin/bash
AWS_REGION=${region}

echo "Syncing the configs of services..."

confd-sync sync -backend dynamodb \
                -table ${confd_table_name} \
                -client-key ${confd_key_arn} \
                -config-file $PWD/services-config.properties \
                -s $PWD/services-secret.properties
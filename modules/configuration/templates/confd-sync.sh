#!/bin/bash
AWS_REGION=${region}
confd-sync sync -e ${confd_table_name} \
                -k ${confd_key_arn} \
                -p $PWD/config.properties \
                -s $PWD/secret.properties
#!/bin/bash

ZONE=asia-northeast1-c

function create_instance() {
  gcloud compute instances create $1 \
    --zone ${ZONE} \
    --machine-type n1-standard-2 \
    --image-project ubuntu-os-cloud \
    --image-family ubuntu-1804-lts \
    --boot-disk-size 200GB
}

create_instance node1
create_instance node2
create_instance node3

#! /usr/bin/env bash
docker buildx bake -f compose.yaml --allow=network.host pi

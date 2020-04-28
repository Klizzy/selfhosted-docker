# Selfhosted Docker

This repo contains all my running services within docker containers.
It's basically a directory structure with docker-compose files, volumes and [watchtower](https://github.com/containrrr/watchtower). 
The main reason for this repository are:

* all applications are always up-to-date
* host machine can be changed easily
* easy backups for application configuration and required files

## Structure
Every application has the following directory structure:
```bash
application_name
|-- confdir
|    -- config_file.yaml
|-- workdir
|    -- ...
|-- docker-compose.yml
```

## Updates & Volumes
Every docker image will be updated every 12 hours trough [watchtower](https://github.com/containrrr/watchtower).
For it to work properly, correct volumes have to be set for all applications.
If that's the case, every application can be updated to the newer version without any loss.



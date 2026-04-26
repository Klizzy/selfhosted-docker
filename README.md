# 🐳 Selfhosted Docker

This repo contains all my running services within docker containers.
It's basically a directory structure with docker-compose files, volumes and [watchtower](https://github.com/containrrr/watchtower). 
The main reason for this repository are:

* applications are kept up-to-date within intentionally chosen version ranges
* host machine can be changed easily
* easy backups for application configuration and required files

## Structure
Every application has the following directory structure:
```bash
application_name
|-- confdir
|    -- application-config-files
|-- workdir
|    -- application-files
|-- .env.dist
|-- docker-compose.yml
```

## Setup
`cd` into the wanted directory and run `docker-compose up -d` to start the service. Some services require an `.env` file so take `.env.dist` and fill in the env variables before start.

## Updates & Volumes
Docker images are checked every 12 hours by [watchtower](https://github.com/containrrr/watchtower).
Watchtower only updates within the version you intentionally pin via the image tag (semantic versioning: major.minor.patch):
- Pin to major (e.g. `myapp:1`) to allow minor/patch updates but prevent automatic upgrades to `2.x`.
- Pin to minor (e.g. `myapp:1.4`) to allow patch updates only.
- Pin to patch (e.g. `myapp:1.4.7`) to lock to an exact version.

Automatic upgrades to a new major version can introduce breaking changes from the provider/vendor. Only move to a new major after reviewing release notes and preparing any required changes.

For updates to be safe, correct volumes have to be set for all applications. If that’s the case, applications can update within the pinned range without data loss.

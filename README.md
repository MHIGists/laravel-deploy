# Laravel Release Deploy

A small Bash deployment script for Laravel applications that prepares immutable Git releases and atomically switches a `current` symlink.

The script is intended for a conventional single-server deployment where Composer, Node.js/npm, PHP, and PHP-FPM are installed on the server.

## What it does

For a requested Git commit, the script:

1. Detects the currently active release.
2. Clones the repository into a temporary directory.
3. Resolves and verifies the requested commit to its full 40-character SHA.
4. Copies the production `.env` file into the release.
5. Installs Composer dependencies.
6. Runs `npm ci` and `npm run build`.
7. Runs Laravel migrations.
8. Moves the prepared release under the deployment root.
9. Sets ownership and Laravel writable-directory permissions.
10. Atomically switches the live symlink.
11. Restarts or reloads PHP-FPM.
12. Restarts Laravel queue workers.
13. Removes old releases while keeping the current and immediately previous releases.

Release directories always use the resolved full commit SHA, so full and abbreviated commit hashes produce the same release path.

## Requirements

- Linux server with Bash
- Git
- PHP and Laravel Artisan
- Composer, unless disabled
- Node.js/npm, unless disabled
- systemd, unless PHP-FPM restart/reload is disabled
- `sudo` when the deploy user cannot write to the deployment root or manage PHP-FPM

The deploy user must also have Git access to the configured repository.

## Installation

Copy `deploy.sh` to the server and make it executable:

```bash
chmod +x deploy.sh
```

Set the repository and any repository-specific settings as environment variables, then pass the commit hash to deploy:

```bash
export DEPLOY_REPOSITORY="git@github.com:owner/example.git"
export DEPLOY_APP_NAME="example"
export DEPLOY_OWNER="deploy"
export DEPLOY_GROUP="www-data"

./deploy.sh 0123456789abcdef0123456789abcdef01234567
```

Abbreviated commit hashes are accepted when Git can resolve them unambiguously:

```bash
./deploy.sh 0123456
```

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `DEPLOY_REPOSITORY` | required | Git clone URL. |
| `DEPLOY_APP_NAME` | repository name | Prefix for release directories and name of the default live symlink. |
| `DEPLOY_ROOT` | `/var/www` | Directory containing releases and the default live symlink. |
| `DEPLOY_CURRENT_LINK` | `<root>/<app>` | Live symlink used by the web server. |
| `DEPLOY_ENV_SOURCE` | `$HOME/.env` | Production environment file copied into each release. |
| `DEPLOY_PREVIOUS_RELEASE_FILE` | `$HOME/.<app>-previous-release` | File containing the previously active release SHA. |
| `DEPLOY_TEMP_ROOT` | `$HOME` | Parent directory for temporary clones. |
| `DEPLOY_OWNER` | current user | Owner applied recursively to each prepared release. |
| `DEPLOY_GROUP` | `www-data` | Group applied recursively to each prepared release. |
| `DEPLOY_PHP_BIN` | `/usr/bin/php` | PHP executable. |
| `DEPLOY_COMPOSER_BIN` | `composer` | Composer executable. |
| `DEPLOY_NPM_BIN` | `npm` | npm executable. |
| `DEPLOY_SUDO_BIN` | `sudo` | Privilege escalation command used when not running as root. |
| `DEPLOY_PHP_FPM_SERVICE` | `php8.4-fpm` | PHP-FPM systemd service name. |
| `DEPLOY_PHP_FPM_ACTION` | `restart` | `restart`, `reload`, or `none`. |
| `DEPLOY_RUN_COMPOSER` | `true` | Run production Composer install. |
| `DEPLOY_RUN_NPM` | `true` | Run npm install/build. |
| `DEPLOY_RUN_MIGRATIONS` | `true` | Run `php artisan migrate --force`. |
| `DEPLOY_RESTART_QUEUE` | `true` | Run `php artisan queue:restart` after switching the release. |

Boolean settings accept `true`, `false`, `1`, `0`, `yes`, `no`, `on`, and `off`.

## Example matching the original Netchek deployment

```bash
export DEPLOY_REPOSITORY="git@github.com:MHIGists/getnetchek.git"
export DEPLOY_APP_NAME="netchek"
export DEPLOY_ROOT="/var/www"
export DEPLOY_ENV_SOURCE="$HOME/.env"
export DEPLOY_OWNER="milko"
export DEPLOY_GROUP="www-data"
export DEPLOY_PHP_FPM_SERVICE="php8.4-fpm"

./deploy.sh <commit-hash>
```

This produces releases such as:

```text
/var/www/netchek-0123456789abcdef0123456789abcdef01234567
```

with `/var/www/netchek` pointing to the active release.

## Per-repository configuration

For repeated deployments, place the exports in a server-local file that is not committed to the application repository, for example `~/deploy-netchek.env`:

```bash
export DEPLOY_REPOSITORY="git@github.com:MHIGists/getnetchek.git"
export DEPLOY_APP_NAME="netchek"
export DEPLOY_OWNER="milko"
export DEPLOY_GROUP="www-data"
```

Then load it before deployment:

```bash
source ~/deploy-netchek.env
./deploy.sh <commit-hash>
```

For an application without frontend assets:

```bash
export DEPLOY_RUN_NPM=false
```

For a deployment where PHP-FPM is managed separately:

```bash
export DEPLOY_PHP_FPM_ACTION=none
```

## Deployment notes

Database migrations run before the live symlink changes. Migrations therefore need to remain compatible with the currently running release until the switch is complete.

The script keeps only two valid release directories for the configured application: the newly deployed release and the release that was active immediately before it. Directories that do not exactly match `<app-name>-<40-character-SHA>` are ignored during cleanup.

The production `.env` is copied into each release and set to mode `640`. Keep the source file outside the repository and protect it appropriately.

## License

MIT. See [LICENSE](LICENSE).

# setup-postgres-action

This action handles the setup and teardown of a PostgreSQL database.

## Usage

See [action.yml](action.yml)

```yaml
steps:
- name: Setup Postgres
  uses: Particular/setup-postgres-action@v1.0.0
  with:
    connection-string-name: <my connection string name>
    init-script: /path/to/init-posgres.sql
    registry-login-server: index.docker.io
    registry-username: ${{ secrets.DOCKERHUB_USERNAME }}
    registry-password: ${{ secrets.DOCKERHUB_TOKEN }}}}    
```

`connection-string-name` is required. `init-script` is optional.

For logging into a container registry when running on Windows:

* `registry-login-server` defaults to `index.docker.io` and is not required if logging into Docker Hub.
* `registry-username` and `registry-password` are optional and will result in pulling the container anonymously if omitted.

On Linux runners the PostgreSQL container runs directly through Docker. On Windows runners the Linux PostgreSQL container runs inside WSL2 (the action installs and starts Docker inside the WSL distribution), so no Azure Container Instances are required.

## License

The scripts and documentation in this project are released under the [MIT License](LICENSE).

## Development

Open the folder in Visual Studio Code. If you don't already have them, you will be prompted to install remote development extensions. After installing them, and re-opening the folder in a container, do the following:

Run the npm installation

```bash
npm install
```

When changing `index.js`, either run `npm run dev` beforehand, which will watch the file for changes and automatically compile it, or run `npm run prepare` afterwards.

## Testing

### With Node.js

To test the setup action an `.env.setup` file in the root directory with the following content

```ini
# Input overrides
INPUT_CONNECTION-STRING-NAME=PostgresConnectionString
INPUT_TAG=setup-postgres-action

# Runner overrides
# Use LINUX to run on Linux, WINDOWS to run on Windows via WSL2
RUNNER_OS=WINDOWS
```

then execute the script 

```bash
node -r dotenv/config dist/index.js dotenv_config_path=.env.setup
```

To test the cleanup action add a `.env.cleanup` file in the root directory with the following content

```ini
# State overrides
STATE_IsPost=true
STATE_containerName=nameOfPreviouslyCreatedContainer
```

```bash
node -r dotenv/config dist/index.js dotenv_config_path=.env.cleanup
```

### With PowerShell

To test the setup action set the required environment variables and execute `setup.ps1` with the desired parameters.

```bash
$Env:RUNNER_OS=Windows
.\setup.ps1 -ContainerName psw-postgres-1 -ConnectionStringName PostgresConnectionString
```

To test the cleanup action set the required environment variables and execute `cleanup.ps1` with the desired parameters.

```bash
$Env:RUNNER_OS=Windows
.\cleanup.ps1 -ContainerName psw-postgres-1
```

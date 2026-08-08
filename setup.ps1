param (
    [string]$ContainerName,
    [string]$ConnectionStringName,
    [string]$InitScript = "",
    [string]$RegistryLoginServer = "index.docker.io",
    [string]$RegistryUser,
    [string]$RegistryPass
)

$dockerImage = "postgres:18"
$password = [guid]::NewGuid().ToString("n")
Write-Output "::add-mask::$password"
$userName = "postgres"
$databaseName = "postgres"
$ipAddress = "127.0.0.1"
$port = 5432
$runnerOs = $Env:RUNNER_OS ?? "Linux"

$env:PGPASSWORD = $password

# Import the WslTools module (Invoke-Wsl) exported by setup-wsl-action. The guard gives a
# clear error if setup-wsl-action hasn't run, since this action no longer provisions WSL itself.
if (-not $Env:WSL_TOOLS_MODULE_PATH) {
    throw "This action requires Particular/setup-wsl-action to run first — it provisions WSL/Docker and exports the WslTools module at WSL_TOOLS_MODULE_PATH."
}
Import-Module $Env:WSL_TOOLS_MODULE_PATH -Force

if ($runnerOs -eq "Linux") {
    Write-Output "Running Postgres in container $($ContainerName) using Docker"

    docker run --name "$($ContainerName)" -d -p "$($port):$($port)" -e POSTGRES_PASSWORD=$password -e POSTGRES_USER=$userName -e POSTGRES_DB=$databaseName $dockerImage -c max_prepared_transactions=10
}
elseif ($runnerOs -eq "Windows") {
    Write-Output "Running Postgres in container $($ContainerName) using WSL"

    # psql is not in PATH on Windows
    $Env:PATH = $Env:PATH + ';' + $Env:PGBIN

    # WSL and Docker were provisioned by setup-wsl-action. Read the distribution and the WSL
    # VM IP from the environment it exported rather than provisioning or detecting them here.
    $wslDistribution = $Env:WSL_DISTRIBUTION
    $ipAddress = $Env:WSL_IP

    if (-not $ipAddress) {
        throw "WSL_IP is not set. Run Particular/setup-wsl-action before this action."
    }
    Write-Output "WSL address: $ipAddress"

    # Optionally log in to the container registry to avoid rate limits when pulling.
    if ($registryUser -and $registryPass) {
        Write-Output "::add-mask::$registryPass"
        Write-Output "Logging in to $RegistryLoginServer inside WSL"
        $loginCommand = "docker login --username '$RegistryUser' --password-stdin '$RegistryLoginServer'"
        $registryPass | wsl.exe --distribution $wslDistribution --user root -- bash -c $loginCommand
        if ($LASTEXITCODE -ne 0) {
            throw "Docker registry login inside WSL failed with exit code $LASTEXITCODE"
        }
    }
    else {
        Write-Output "Using anonymous credentials"
    }

    Write-Output "::group::Starting PostgreSQL container"
    Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "docker run --name $ContainerName --detach --restart unless-stopped --publish ${port}:${port} -e POSTGRES_PASSWORD='$password' -e POSTGRES_USER='$userName' -e POSTGRES_DB='$databaseName' $dockerImage -c max_prepared_transactions=10"
    Invoke-Wsl -Distribution $wslDistribution -Command "docker ps --filter name=$ContainerName"
    Write-Output "::endgroup::"
}
else {
    Write-Output "$runnerOs not supported"
    exit 1
}

Write-Output "::group::Testing connection"

# PGCONNECT_TIMEOUT bounds each attempt; without it an unreachable host hangs on the OS TCP timeout (~21s/attempt).
$env:PGCONNECT_TIMEOUT = "5"

$connectionAttempts = 24
$connected = $false
for ($i = 0; $i -lt $connectionAttempts; $i++) {
    Write-Output "Checking for PostgreSQL connectivity $($i + 1)/$connectionAttempts..."
    # SELECT 1 is version-agnostic. `--list` runs a catalog query whose column names change
    # across major versions (e.g. daticulocale -> datlocale), which breaks when the runner's
    # older psql client probes a newer server (psql 15/16 vs postgres:18).
    psql --host $ipAddress --username=$userName --command "SELECT 1" > $null
    if ($?) {
        $connected = $true
        Write-Output "Connection successful"
        break
    }
    sleep 5
}

if (-not $connected) {
    throw "PostgreSQL at ${ipAddress}:${port} never accepted a connection after $connectionAttempts attempts. The container may have failed to start, or the host is unreachable from the runner. Check the container status (docker ps / container logs); on Windows runners confirm the WSL VM IP exported by setup-wsl-action (${ipAddress}) is reachable from the runner."
}

Write-Output "::endgroup::"

# write the connection string to the specified environment variable
"$($ConnectionStringName)=User ID=$($userName);Password=$($password);Host=$($ipAddress);Port=$($port);Database=$($databaseName);" >> $Env:GITHUB_ENV

if ($InitScript) {
    Write-Output "::group::Running init script $InitScript"

    $script = Get-Content $InitScript -Raw
    psql --host $ipAddress --username=$userName --command $script
    if (-not $?) {
        Write-Output "Script execution failed"
      exit 1
    }

    Write-Output "::endgroup::"
}

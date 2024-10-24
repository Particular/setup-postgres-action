param (
    [string]$ContainerName,
    [string]$ConnectionStringName,
    [string]$InitScript = "",
    [string]$Tag,
    [string]$RegistryLoginServer = "index.docker.io",
    [string]$RegistryUser,
    [string]$RegistryPass
)

$dockerImage = "postgres:15"
$password = [guid]::NewGuid().ToString("n")
Write-Output "::add-mask::$password"
$userName = "postgres"
$databaseName = "postgres"
$ipAddress = "127.0.0.1"
$port = 5432
$runnerOs = $Env:RUNNER_OS ?? "Linux"
$resourceGroup = $Env:RESOURCE_GROUP_OVERRIDE ?? "GitHubActions-RG"

$env:PGPASSWORD = $password

if ($runnerOs -eq "Linux") {
    Write-Output "Running Postgres in container $($ContainerName) using Docker"

    docker run --name "$($ContainerName)" -d -p "$($port):$($port)" -e POSTGRES_PASSWORD=$password -e POSTGRES_USER=$userName -e POSTGRES_DB=$databaseName $dockerImage -c max_prepared_transactions=10
}
elseif ($runnerOs -eq "Windows") {
    Write-Output "Running Postgres in container $($ContainerName) using Azure"

    if ($Env:REGION_OVERRIDE) {
        $region = $Env:REGION_OVERRIDE
    }
    else {
        $hostInfo = curl -H Metadata:true "169.254.169.254/metadata/instance?api-version=2017-08-01" | ConvertFrom-Json
        $region = $hostInfo.compute.location
    }

    $runnerOsTag = "RunnerOS=$($runnerOs)"
    $packageTag = "Package=$Tag"
    $dateTag = "Created=$(Get-Date -Format "yyyy-MM-dd")"

    # psql not in PATH on Windows
    $Env:PATH = $Env:PATH + ';' + $Env:PGBIN
       
    $azureContainerCreate = "az container create --image $dockerImage --name $ContainerName --location $region --resource-group $resourceGroup --cpu 2 --memory 8 --ports $port --ip-address public --environment-variables POSTGRES_PASSWORD='$password' POSTGRES_USER=$userName POSTGRES_DB=$databaseName --command-line 'docker-entrypoint.sh postgres --max-prepared-transactions=10'"
    if ($registryUser -and $registryPass) {
        Write-Output "Creating container with login to $RegistryLoginServer"
        $azureContainerCreate =  "$azureContainerCreate --registry-login-server $RegistryLoginServer --registry-username $RegistryUser --registry-password $RegistryPass"
    } else {
        Write-Output "Creating container with anonymous credentials"
    }

    Write-Output "Creating container $ContainerName in $region (this can take a while)"
    echo $azureContainerCreate
    $containerJson = Invoke-Expression $azureContainerCreate
    
    if (!$containerJson) {
        Write-Output "Failed to create container $ContainerName in $region"
        exit 1;
    }
    
    $containerDetails = $containerJson | ConvertFrom-Json
    
    if (!$containerDetails.ipAddress) {
        Write-Output "Failed to create container $ContainerName in $region"
        Write-Output $containerJson
        exit 1;
    }

    $ipAddress = $containerDetails.ipAddress.ip
    Write-Output "::add-mask::$ipAddress"

    Write-Output "Tagging the container"
    az tag create --resource-id $containerDetails.id --tags $packageTag $runnerOsTag $dateTag | Out-Null

}
else {
    Write-Output "$runnerOs not supported"
    exit 1
}

Write-Output "::group::Testing connection"

for ($i = 0; $i -lt 24; $i++) { ## 2 minute timeout
    Write-Output "Checking for PostgreSQL connectivity $($i+1)/30..."
    psql --host $ipAddress --username=$userName --list > $null
    if ($?) {
        Write-Output "Connection successful"
      break;
    }
    sleep 5
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

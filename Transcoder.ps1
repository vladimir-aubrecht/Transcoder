$ffmpegPath = "D:\Transcoding\ffmpeg.exe"
$ffprobePath = "D:\Transcoding\ffprobe.exe"
$transcodedExtension = "mp4"

function Transcoder-ProcessFile($SourcePath, $DestinationPath)
{
    if (Test-Path -Path $DestinationPath)
    {
        Write-Warning -Message "File $DestinationPath already exists, skipping ..."
        return
    }
    
    $mp4DestinationPath = [System.IO.Path]::ChangeExtension($DestinationPath, $transcodedExtension)
    if (Test-Path -Path $mp4DestinationPath)
    {
        Write-Warning -Message "File $mp4DestinationPath already exists, skipping ..."
        return
    }
    
    $dirPath = [System.IO.Path]::GetDirectoryName($DestinationPath)
    
    Transcoder-CreateFolderStructure -FolderPath $dirPath
    
    if (Transcoder-IsVideo -SourcePath $SourcePath)
    {
        & $ffmpegPath -i "$SourcePath" -c:v libx265 -crf 28 -preset fast -vtag hvc1 -c:a copy -c:s copy "$mp4DestinationPath"
    }
    else
    {
        Copy-Item -Path $SourcePath -Destination $DestinationPath
    }
}

function Transcoder-ProcessList($SourceList, $DestinationList)
{
    $jobs = @()
    
    $index = 0

    $sourceList | foreach {
        $originalFilePath = $_.FullName
        $transcodedFilePath = $DestinationList[$index]
        
        $ScriptBlock = {
            param($srcFilePath, $destFilePath, $scriptPath) 
            
            . $scriptPath

            Transcoder-ProcessFile -SourcePath $srcFilePath -DestinationPath $destFilePath
          }

        $jobs += Start-Job $ScriptBlock -ArgumentList ($originalFilePath, $transcodedFilePath, $PSCommandPath)

        $index++
    }

    $jobs | Receive-Job -Wait -AutoRemoveJob
}

function Transcoder-ProcessFolder($SourcePath, $DestinationPath, $groupSize = 6)
{
    $sourceGroups = @()
    $destinationGroups = @()
    
    $index = 0
    Get-ChildItem -Path $SourcePath -Recurse | foreach {
        
        if ((Test-Path -PathType container $_.FullName))
        {
            return
        }

        if ($sourceGroups.Count -eq $index)
        {
            $sourceGroups += , @()
            $destinationGroups += , @()
        }

        $sourceGroups[$index] += $_
        $destinationGroups[$index] += $_.FullName.Replace($SourcePath, $destinationPath)
        
        if ($sourceGroups[$index].Count -eq $groupSize)
        {
            $index++
        }
    }

    $index = 0
    $sourceGroups | foreach {
        Transcoder-ProcessList -SourceList $_ -DestinationList $destinationGroups[$index]
        $index++
    }
}

function Transcoder-ListContainer($SourcePath)
{
    ConvertFrom-Json (& $ffprobePath -v quiet -output_format json -show_format -show_streams $SourcePath | Out-String)
}

function Transcoder-IsVideo($SourcePath)
{
    $isVideo = $false

    $streams = (Transcoder-ListContainer -SourcePath $SourcePath).streams

    $streams | foreach {
        if ($_.codec_type -eq "video" -and $_.duration_ts -gt 1) {
            $isVideo = $true
        }
    }

    return $isVideo
}

function Transcoder-CreateFolderStructure($FolderPath)
{
    If(!(Test-Path -PathType container $folderPath))
    {
      New-Item -ItemType Directory -Path $folderPath
    }
}

function test()
{
    Transcoder-ProcessFile -SourcePath "D:\Transcoding\Encode\Addams Family\Season 1\Addams.Family.S01E01-CZSub-aac.m4v" -DestinationPath "D:\Transcoding\Finished\Addams Family\Season 1\Addams.Family.S01E01-CZSub-aac.mp4"
}
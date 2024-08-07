﻿$ffmpegPath = "D:\Transcoding\ffmpeg.exe"
$ffprobePath = "D:\Transcoding\ffprobe.exe"
$transcodedExtension = "mp4"

$crfTable = @{ '480p'='28'; '720p'='24'; '1080p'='24'; '2160p'='24' }

class TrackConfiguration
{
    [Collections.Generic.Dictionary[string, int32]] $Disposition = @{}
    [Collections.Generic.Dictionary[string, string]] $Tags = @{}

    [void] Deserialise($hashTable)
    {
        $d = @{}
        $t = @{}
        
        $hashTable.Disposition.psobject.properties | Foreach { $d[$_.Name] = $_.Value }
        $hashTable.Tags.psobject.properties | Foreach { $t[$_.Name] = $_.Value }

        $d.Keys | foreach {
            $key = $_
            $this.Disposition.Add($key, $d[$key])
        }

        $t.Keys | foreach {
            $key = $_
            
            $this.Tags.Add($key, $t[$key])
        }
        
    }
}

class TranscoderConfiguration
{
  [int32] $GroupSize = 6
  [boolean] $EnablePngTrackDropping = $false
  [boolean] $EnableSubtitleTrackDropping = $false
  [TrackConfiguration[]] $TrackConfigurations = @()

  [void] Deserialize($hashTable)
  {
    $this.GroupSize = $hashTable.GroupSize
    $this.EnablePngTrackDropping = $hashTable.EnablePngTrackDropping
    $this.EnableSubtitleTrackDropping = $hashTable.EnableSubtitleTrackDropping
    
    $this.TrackConfigurations = @($null) * $hashTable.TrackConfigurations.Count

    $index = 0
    $hashTable.TrackConfigurations | foreach {
        $tc = [TrackConfiguration]::new()
        
        $tc.Deserialise($hashTable.TrackConfigurations[$index])

        $this.TrackConfigurations[$index] = $tc

        $index++
    }
  }
}

function Transcoder-ProcessFile($SourcePath, $DestinationPath, [TranscoderConfiguration] $Configuration = [TranscoderConfiguration]::new())
{
    $SourcePath = $SourcePath.TrimEnd('\')
    $DestinationPath = $DestinationPath.TrimEnd('\')

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
        $audioMetadaArguments = ""
        $dispositionMetadataArguments = ""

        $index = 0
        $Configuration.TrackConfigurations | foreach {
            [TrackConfiguration] $trackConfiguration = $_
            
            $trackConfiguration.Tags.Keys | foreach {
                $key = $_
                $value = $trackConfiguration.Tags[$key]

                $audioMetadaArguments += " -metadata:s:a:$index $key=$value"
            }

            $trackConfiguration.Disposition.Keys | foreach {
                $key = $_
                $value = $trackConfiguration.Disposition[$key]

                $v = $key

                if ($value -eq 0) {
                    $v = 0
                }

                $dispositionMetadataArguments += " -disposition:a:$index $v"
            }

            $index++
        }

        $excludeTracksArguments = ""

        $streams = (Transcoder-ListContainer -SourcePath $SourcePath).streams
        
        $videoStream = $streams | where { $_.codec_type -eq 'video' -and ($_.duration_ts -gt 1 -or $_.start_pts -gt 100 -or $_.disposition.default -eq 1 ) }
        $subtitleStreams = $streams | where { $_.codec_type -eq 'subtitle' }
        
        $videoCodec = 'libx265'
        $subtitleCodec = '-c:s copy'

        if ($videoStream.codec_name -eq 'hevc') {
            $videoCodec = 'copy'
        }
        
        if ($subtitleStreams.codec_name -ne 'mov_text') {
            $subtitleCodec = '-c:s mov_text'
        }

        if ($subtitleStreams.codec_name -eq 'hdmv_pgs_subtitle') {
            $subtitleCodec = '-sn'
        }
        
        $Configuration
        if ($Configuration.EnableSubtitleTrackDropping -eq $true)
        {
            $subtitleCodec = '-sn'
        }

        $crf = '28'
        if ($videoStream.coded_height -ge 720) {
            $crf = $crfTable['720p']
        }
        if ($videoStream.coded_height -ge 1080) {
            $crf = $crfTable['1080p']
        }
        if ($videoStream.coded_height -ge 2160) {
            $crf = $crfTable['2160p']
        }


        if ($Configuration.EnablePngTrackDropping) {
            $pngTracks = ($streams | where { $_.codec_name -eq 'png' -or $_.codec_name -eq 'mjpeg' }) | select -Property index

            $pngTracks | foreach {
                $i = $_.index
                $excludeTracksArguments += " -map -0:$i"
            }
        }

        $metadataArguments = $audioMetadaArguments.Substring(1) + $dispositionMetadataArguments
        
        Write-Information "Using CRF: $crf"
        
        "& $ffmpegPath -i `"$SourcePath`" -map 0$excludeTracksArguments -c:v $videoCodec -crf $crf -preset fast -vtag hvc1 -c:a copy $metadataArguments $subtitleCodec `"$mp4DestinationPath`""
        iex "& $ffmpegPath -i `"$SourcePath`" -map 0$excludeTracksArguments -c:v $videoCodec -crf $crf -preset fast -vtag hvc1 -c:a copy $metadataArguments $subtitleCodec `"$mp4DestinationPath`""
    }
    else
    {
        Copy-Item -Path "$SourcePath" -Destination "$DestinationPath"
    }
}

function Transcoder-ProcessList($SourceList, $DestinationList, [TranscoderConfiguration] $Configuration = [TranscoderConfiguration]::new())
{
    $jobs = @()
    
    $index = 0
    
    $sourceList | foreach {
        $originalFilePath = $_.FullName
        $transcodedFilePath = $DestinationList[$index]
        
        $ScriptBlock = {
            param($srcFilePath, $destFilePath, $blockConfiguration, $scriptPath) 

            . $scriptPath
            #$blockConfiguration
            
            $hashTable = @{}
            (ConvertFrom-Json $blockConfiguration).psobject.properties | Foreach { $hashTable[$_.Name] = $_.Value }


            [TranscoderConfiguration] $conf = [TranscoderConfiguration]::new()
            $conf.Deserialize($hashTable)

            Transcoder-ProcessFile -SourcePath $srcFilePath -DestinationPath $destFilePath -Configuration $conf
          }

        $jobs += Start-Job $ScriptBlock -ArgumentList ($originalFilePath, $transcodedFilePath, (ConvertTo-Json $Configuration -Depth 10), $PSCommandPath)

        $index++
    }

    $jobs | Receive-Job -Wait -AutoRemoveJob
}

function Transcoder-ProcessFolder($SourcePath, $DestinationPath, [TranscoderConfiguration] $Configuration = [TranscoderConfiguration]::new())
{
    $SourcePath = $SourcePath.TrimEnd('\')
    $DestinationPath = $DestinationPath.TrimEnd('\')

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
        
        if ($sourceGroups[$index].Count -eq $Configuration.GroupSize)
        {
            $index++
        }
    }

    $index = 0
    $sourceGroups | foreach {
        Transcoder-ProcessList -SourceList $_ -DestinationList $destinationGroups[$index] -Configuration $Configuration
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
    
    if ($streams.Count -eq 1) {
        return $false
    }
    
    $streams | foreach {
        if ($_.codec_type -eq "video" -and ($_.duration_ts -gt 1 -or $_.start_pts -gt 100 -or $_.disposition.default -eq 1 )) {
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

function Transcoder-CreateAudioConfig($LanguageList, $DefaultList)
{
    if ($DefaultList -eq $null)
    {
        $DefaultList = $LanguageList | foreach { if ($_ -eq 'eng') { '1' } else { '0' } }
    }

    $trackDictionary = @($null) * $LanguageList.Count

    $index = 0
    
    $LanguageList | foreach {
        $audio = [TrackConfiguration]::new()
        $audio.Tags.Add("language", $_)
        $audio.Disposition.Add("default", ($DefaultList[$index]))
        $trackDictionary[$index] = $audio
        
        $index++
    }

    $conf = [TranscoderConfiguration]::new()
    $conf.TrackConfigurations = $trackDictionary

    return $conf
}
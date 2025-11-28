$ffmpegPath = "D:\Transcoding\ffmpeg.exe"
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
  [boolean] $EnableIncompatibleTrackDropping = $false
  [boolean] $EnableSubtitleTrackDropping = $false
  [boolean] $ForceVideoTranscoding = $false
  [TrackConfiguration[]] $TrackConfigurations = @()
  [int32] $EnforcedResolution = 0

  [void] Deserialize($hashTable)
  {
    $this.GroupSize = $hashTable.GroupSize
    $this.EnableIncompatibleTrackDropping = $hashTable.EnableIncompatibleTrackDropping
    $this.EnableSubtitleTrackDropping = $hashTable.EnableSubtitleTrackDropping
    $this.ForceVideoTranscoding = $hashTable.ForceVideoTranscoding
    $this.EnforcedResolution = $hashTable.EnforcedResolution
    
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

        if ($videoStream.codec_name -eq 'hevc' -and $Configuration.ForceVideoTranscoding -eq $false) {
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


        $pickedHeight = $videoStream.coded_height
        $scale = ""

        if ($Configuration.EnforcedResolution -ne 0)
        {
            $ratio = $Configuration.EnforcedResolution / $videoStream.coded_height
            $newWidth = $videoStream.coded_width * $ratio

            $pickedHeight = $Configuration.EnforcedResolution

            $scale = "-vf scale=-1:" + $Configuration.EnforcedResolution + " "
            $videoCodec = 'libx265'
        }

        $crf = '28'
        if ($pickedHeight -ge 720) {
            $crf = $crfTable['720p']
        }
        if ($pickedHeight -ge 1080) {
            $crf = $crfTable['1080p']
        }
        if ($pickedHeight -ge 2160) {
            $crf = $crfTable['2160p']
        }


        if ($Configuration.EnableIncompatibleTrackDropping) {
            $pngTracks = ($streams | where { $_.codec_name -eq 'png' -or $_.codec_name -eq 'mjpeg' -or $_.codec_name -eq 'ttf' -or $_.codec_name -eq 'dvd_subtitle' -or $_.codec_name -eq 'hdmv_pgs_subtitle' }) | select -Property index

            $pngTracks | foreach {
                $i = $_.index
                $excludeTracksArguments += " -map -0:$i"
            }
        }

        $metadataArguments = $audioMetadaArguments.Substring(1) + $dispositionMetadataArguments
        
        Write-Information "Using CRF: $crf"
        
        "& $ffmpegPath -i `"$SourcePath`" $scale-map 0$excludeTracksArguments -c:v $videoCodec -crf $crf -preset fast -vtag hvc1 -c:a copy $metadataArguments $subtitleCodec `"$mp4DestinationPath`""
        iex "& $ffmpegPath -i `"$SourcePath`" $scale-map 0$excludeTracksArguments -c:v $videoCodec -crf $crf -preset fast -vtag hvc1 -c:a copy $metadataArguments $subtitleCodec `"$mp4DestinationPath`""
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
        if ($_.codec_type -eq "video" -and ($_.duration_ts -gt 1 -or $_.start_pts -gt 100 -or $_.disposition.default -eq 1 -or $_.has_b_frames -gt 0 )) {
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
        $DefaultList = @()
        $LanguageList | foreach { if ($_ -eq 'eng') { $DefaultList += @('1') } else { $DefaultList += @('0') } }
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

function Transcoder-ListContainersWithMultipleAudios($RootPath, $Filter = "*.mp4")
{
    $allStreams = Get-ChildItem $RootPath -Recurse -Filter $Filter | foreach { @{ $_.FullName=(Transcoder-ListContainer $_.FullName)} }
    $allStreams | foreach { $filename = $_.Keys; $_.Values.streams | where { $_.codec_type -eq 'audio' } | where { $_.index -gt 1 } | foreach { $filename } }
}

function Transcoder-IsHdrVideo($SourcePath)
{
    $streams = (Transcoder-ListContainer -SourcePath $SourcePath).streams
    
    if ($streams.Count -eq 1) {
        return $false
    }
    
    $videoIndex = -1
    $index = 0

    $streams | foreach {
        if ($_.codec_type -eq "video" -and ($_.duration_ts -gt 1 -or $_.start_pts -gt 100 -or $_.disposition.default -eq 1 -or $_.has_b_frames -gt 0 )) {
            $videoIndex = $index
        }

        $index++
    }

    $ct = $streams[$videoIndex].color_transfer

    return $ct -ne $null -and ( $ct -eq 'smpte2084' -or $ct -eq 'arib-std-b67')
}

function Transcoder-FixAudioMetadata($OriginalFilePath, $fileToFixPath)
{
    if (-not (Test-Path $OriginalFilePath))
    {
        Write-Error "Original file does not exist"
        return
    }

    if (-not (Test-Path $fileToFixPath))
    {
        Write-Error "File to fix does not exist"
        return
    }

    $originalStreams = (Transcoder-ListContainer $OriginalFilePath).streams | where { $_.codec_type -eq 'audio' } | Sort-Object -Property index
    $streamsToFix = (Transcoder-ListContainer $fileToFixPath).streams | where { $_.codec_type -eq 'audio' } | Sort-Object -Property index

    $originalLanguages = $originalStreams.tags.language
    $newLanguages = $streamsToFix.tags.language

    $areLanguagesSame = $originalLanguages.Count -eq $newLanguages.Count

    for ($i = 0; $i -lt $originalLanguages.Count; $i++)
    {
        $areLanguagesSame = $areLanguagesSame -and $originalLanguages[$i] -eq $newLanguages[$i]
    }

    if ($areLanguagesSame)
    {
        Write-Information "Languages are same, skipping fixing ..."
        return
    }

    $conf = Transcoder-CreateAudioConfig -LanguageList $originalLanguages

    Transcoder-ProcessFile -SourcePath $fileToFixPath -DestinationPath "$fileToFixPath.mp4" -Configuration $conf

    rm "$fileToFixPath"
    mv "$fileToFixPath.mp4" "$fileToFixPath"
}

function Transcoder-FixAudioMetadataForFolders($OriginalFolderPath, $folderToFixPath)
{
    ls $folderToFixPath | foreach {
        $folderToFixFile = $_

        if ($folderToFixFile.Extension -eq '.mp4')
        {
            $originalFile = (ls $OriginalFolderPath | where { $_.BaseName -eq $folderToFixFile.BaseName }).FullName
        
            if (Transcoder-IsVideo -SourcePath $originalFile)
            {
                $fixFile = $folderToFixFile.FullName
                Transcoder-FixAudioMetadata -OriginalFilePath $originalFile -fileToFixPath $fixFile
            }
        }
    }
}

function Transcoder-GenerateMd5($Path)
{
    Get-ChildItem -Path $Path -Recurse -Exclude "*.md5" -File | ForEach-Object {
        $md5path =  $_.FullName + ".md5"
        
        if (!(Test-Path $md5path)) {
            $_.FullName
            $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm MD5
            $hash | Select-Object -ExpandProperty Hash | Out-File -LiteralPath $md5path -Encoding ASCII
        }
    }

}



function Compare-HashTrees {
    param(
        [Parameter(Mandatory=$true)][string]$Path1,
        [Parameter(Mandatory=$true)][string]$Path2
    )

    # Normalize root paths (remove trailing slash/backslash)
    $root1 = $Path1.TrimEnd('\','/')
    $root2 = $Path2.TrimEnd('\','/')

    # Collect all .md5 files under each root
    $hashFiles1 = Get-ChildItem -Path $root1 -Recurse -Filter '*.md5' -File
    $hashFiles2 = Get-ChildItem -Path $root2 -Recurse -Filter '*.md5' -File

    $mismatches = $false

    # Build a lookup of relative paths → full path for Tree2
    $lookup2 = @{}
    foreach ($h2 in $hashFiles2) {
        $rel2 = $h2.FullName.Substring($root2.Length + 1)
        # Normalize to use backslashes
        $rel2 = $rel2 -replace '/','\'
        $lookup2[$rel2.ToLower()] = $h2.FullName
    }

    # Compare every .md5 in Tree1 against Tree2
    foreach ($h1 in $hashFiles1) {
        $rel1 = $h1.FullName.Substring($root1.Length + 1)
        $rel1 = $rel1 -replace '/','\'
        $key = $rel1.ToLower()

        if ($lookup2.ContainsKey($key)) {
            $path2hash = $lookup2[$key]
            try {
                $hash1 = Get-Content -LiteralPath $h1.FullName -ErrorAction Stop
                $hash2 = Get-Content -LiteralPath $path2hash -ErrorAction Stop
            }
            catch {
                Write-Host "Error reading hash files for '$rel1': $($_.Exception.Message)" -ForegroundColor Yellow
                $mismatches = $true
                continue
            }
            if ($hash1.Trim() -ne $hash2.Trim()) {
                Write-Host "HASH MISMATCH: '$rel1'" -ForegroundColor Red
                Write-Host "  $Path1 → $hash1"
                Write-Host "  $Path2 → $hash2"
                $mismatches = $true
            }
            # Remove from lookup so remaining entries in Tree2 can be detected as extra
            $lookup2.Remove($key)
        }
        else {
            Write-Host "MISSING IN Path2: '$rel1'" -ForegroundColor Yellow
            $mismatches = $true
        }
    }

    # Any leftovers in lookup2 are .md5 files present in Tree2 but not in Tree1
    foreach ($extra in $lookup2.Keys) {
        Write-Host "EXTRA IN Path2: '$extra'" -ForegroundColor Yellow
        $mismatches = $true
    }

    if (-not $mismatches) {
        Write-Host "All .md5 files match between '$Path1' and '$Path2'." -ForegroundColor Green
        return $true
    }
    else {
        Write-Host "Discrepancies were found." -ForegroundColor Red
        return $false
    }
}


function Transcoder-ExtractAudio($folderPath)
{
    Get-ChildItem $folderPath -Recurse | where { Transcoder-IsVideo -SourcePath $_ } | foreach { 
        $fullName = $_.FullName
        $outputName = $fullName.Replace($_.Name, $_.BaseName + ".aac");

        &$ffmpegPath -i $_.Fullname -vn -acodec copy $outputName
    }
}

function Transcoder-AddAudio($videoFilePath, $audioFilePath, $audioLanguageCode, $offsetInSeconds = 0)
{
   $outputPath = [System.IO.Path]::GetFileNameWithoutExtension($videoFilePath) + ".merged" + [System.IO.Path]::GetExtension($videoFilePath)

   &$ffmpegPath -i $videoFilePath -itsoffset $offsetInSeconds -i $audioFilePath -map 0 -map 1:a:0 -c copy -metadata:s:a:0 language=$audioLanguageCode $outputPath
}
#!/bin/bash
# Geospatial Data Processing Workflow
# Copyright (C) 2021, Wouter Knoben
# Copyright (C) 2022-2023, University of Saskatchewan
# Copyright (C) 2023, University of Calgary
#
# This file is part of Geospatial Data Processing Workflow
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# =========================
# Credits and contributions
# =========================
# 1. Parts of the code are taken from https://www.shellscript.sh/tips/getopt/index.html
# 2. General ideas of GeoTIFF subsetting are taken from https://github.com/CH-Earth/CWARHM
#    developed mainly by Wouter Knoben (hence the header copyright credit). See the preprint
#    at: https://www.essoar.org/doi/10.1002/essoar.10509195.1


# ================
# General comments
# ================
# * All variables are camelCased for distinguishing from function names;
# * function names are all in lower_case with words seperated by underscore for legibility;
# * shell style is based on Google Open Source Projects'
#   Style Guide: https://google.github.io/styleguide/shellguide.html


# ===============
# Usage Functions
# ===============
short_usage() {
  echo "usage: $(basename $0) -cio DIR -v var1[,var2[...]] [-r INT] [-se DATE] [-ln REAL,REAL] [-f PATH] [-F STR] [-t BOOL] [-a stat1[,stat2,[...]] [-u BOOL] [-q q1[,q2[...]]]] [-p STR] "
}


# argument parsing using getopt - WORKS ONLY ON LINUX BY DEFAULT
parsedArguments=$(getopt -a -n modis -o i:o:v:r:s:e:l:n:f:F:t:a:u:q:p:c:L: --long dataset-dir:,output-dir:,variable:,crs:,start-date:,end-date:,lat-lims:,lon-lims:,shape-file:,fid:,print-geotiff:,stat:,include-na:,quantile:,prefix:,cache:,lib-path: -- "$@")
validArguments=$?
if [ "$validArguments" != "0" ]; then
  short_usage;
  exit 1;
fi

# check if no options were passed
if [ $# -eq 0 ]; then
  echo "$(basename $0): ERROR! arguments missing";
  exit 1;
fi

# check long and short options passed
eval set -- "$parsedArguments"
while :
do
  case "$1" in
    -i | --dataset-dir)   geotiffDir="$2"      ; shift 2 ;; # required
    -o | --output-dir)    outputDir="$2"       ; shift 2 ;; # required
    -v | --variable)      variables="$2"       ; shift 2 ;; # required
    -r | --crs)           crs="$2"             ; shift 2 ;; # required 
    -s | --start-date)    startDate="$2"       ; shift 2 ;; # required
    -e | --end-date)      endDate="$2"         ; shift 2 ;; # required
    -l | --lat-lims)      latLims="$2"         ; shift 2 ;; # required - could be redundant
    -n | --lon-lims)      lonLims="$2"         ; shift 2 ;; # required - could be redundant
    -f | --shape-file)    shapefile="$2"       ; shift 2 ;; # required - could be redundant
    -F | --fid)           fid="$2"             ; shift 2 ;; # optional
    -t | --print-geotiff) printGeotiff="$2"    ; shift 2 ;; # required
    -a | --stat)          stats="$2"           ; shift 2 ;; # optional
    -u | --include-na)    includeNA="$2"       ; shift 2 ;; # required
    -q | --quantile)      quantiles="$2"       ; shift 2 ;; # optional
    -p | --prefix)        prefix="$2"          ; shift 2 ;; # optional
    -c | --cache)         cache="$2"           ; shift 2 ;; # required
    -L | --lib-path)      renvCache="$2"       ; shift 2 ;; # required

    # -- means the end of the arguments; drop this, and break out of the while loop
    --) shift; break ;;

    # in case of invalid option
    *)
      echo "$(basename $0): ERROR! invalid option '$1'";
      short_usage; exit 1 ;;
  esac
done

# check if $ensemble is provided
if [[ -z "$startDate" ]] || [[ -z "$endDate" ]]; then
  echo "$(basename $0): Warning! time extents missing, considering full time range";
  startDate="2001"
  endDate="2020"
fi

# check the prefix if not set
if [[ -z $prefix ]]; then
  prefix="modis_"
fi

# parse comma-delimited variables
IFS=',' read -ra variables <<< "${variables}"


# =====================
# Necessary Assumptions
# =====================
# TZ to be set to UTC to avoid invalid dates due to Daylight Saving
alias date='TZ=UTC date'
# expand aliases for the one stated above
shopt -s expand_aliases

# necessary hard-coded paths
exactextractrCache="${renvCache}/exact-extract-env" # exactextractr renv cache path
renvPackagePath="${renvCache}/renv_1.1.1.tar.gz" # renv_1.1.1 source path
gistoolPath="$(dirname $0)/../../../../../" # gistool's path 


# =================
# Useful One-liners
# =================
# sorting a comma-delimited string of real numbers
sort_comma_delimited () { IFS=',' read -ra arr <<< "$*"; echo ${arr[*]} | tr " " "\n" | sort -n | tr "\n" " "; }

# log date format
logDate () { echo "($(date +"%Y-%m-%d %H:%M:%S")) "; }


#######################################
# subset GeoTIFFs
#
# Globals:
#   latLims: comma-delimited latitude
#            limits
#   lonLims: comma-delimited longitude
#            limits
#
# Arguments:
#   sourceVrt: source vrt file (or
# 	       tif!)
#   destPath: destionation path (inclu-
#	      ding file name)
#
# Outputs:
#   one mosaiced (merged) GeoTIFF under
#   the $destDir
#######################################
subset_geotiff () {
  # local variables
  local latMin
  local latMax
  local lonMin
  local lonMax
  local sortedLats
  local sortedLons
  # reading arguments
  local sourceVrt="$1"
  local destPath="$2"

  # extracting minimum and maximum of latitude and longitude respectively
  ## latitude
  sortedLats=($(sort_comma_delimited "$latLims"))
  latMin="${sortedLats[0]}"
  latMax="${sortedLats[1]}"
  ## longitude
  sortedLons=($(sort_comma_delimited "$lonLims"))
  lonMin="${sortedLons[0]}"
  lonMax="${sortedLons[1]}"

  # subset based on lat/lon - flush to disk at 500MB
  GDAL_CACHEMAX=500
  gdal_translate \
    --config GDAL_CACHEMAX 500 \
    -co COMPRESS="DEFLATE" \
    -co BIGTIFF="YES" \
    -projwin $lonMin $latMax $lonMax $latMin "${sourceVrt}" "${destPath}"; 
}


# ===============
# Data Processing
# ===============
# display info
echo "$(logDate)$(basename $0): processing MODIS HDF(s)..."

# make the cache directory
echo "$(logDate)$(basename $0): creating cache directory under $cache"
mkdir -p "$cache"

# make the output directory
echo "$(logDate)$(basename $0): creating output directory under $outputDir"
mkdir -p "$outputDir" # making the output directory

# extract the start and end years
startYear="$(date --date="$startDate" +"%Y")"
endYear="$(date --date="$endDate" +"%Y")"
yearsRange=($(seq $startYear $endYear))

# if shapefile is provided extract the extents from it
if [[ -n $shapefile ]]; then
  # extract the shapefile extent
  IFS=' ' read -ra shapefileExtents <<< "$(ogrinfo -so -al "$shapefile" | sed 's/[),(]//g' | grep Extent)"
  # transform the extents in case they are not in EPSG:4326
  IFS=':' read -ra sourceProj4 <<< "$(gdalsrsinfo $shapefile | grep -e "PROJ.4")" # source Proj4 value
  if [[ -n $sourceProj4 ]]; then
    :
  else
    echo "$(logDate)$(basename $0): WARNING! Assuming WSG84 CRS for the input ESRI shapefile"
    sourceProj4=("PROJ.4" " +proj=longlat +datum=WGS84 +no_defs") # made an array for compatibility with the following statements
  fi
 
  # transform limits and assing to variables
  IFS=' ' read -ra leftBottomLims <<< $(echo "${shapefileExtents[@]:1:2}" | gdaltransform -s_srs "${sourceProj4[1]}" -t_srs EPSG:4326 -output_xy)
  IFS=' ' read -ra rightTopLims <<< $(echo "${shapefileExtents[@]:4:5}" | gdaltransform -s_srs "${sourceProj4[1]}" -t_srs EPSG:4326 -output_xy)
  # define $latLims and $lonLims from $shapefileExtents
  lonLims="${leftBottomLims[0]},${rightTopLims[0]}"
  latLims="${leftBottomLims[1]},${rightTopLims[1]}"
fi

# build .vrt file out of annual MODIS HDFs for each of the $variables
echo "$(logDate)$(basename $0): building virtual format (.vrt) of MODIS HDFs under $cache"
for var in "${variables[@]}"; do
  echo "$(logDate)$(basename $0): processing variable $var"
  for yr in "${yearsRange[@]}"; do
    echo "$(logDate)$(basename $0): processing year $yr"
    # format year to conform to MODIS nomenclature
    yrFormatted="${yr}.01.01"
    
    # create temporary directories for each variable
    mkdir -p "${cache}/${var}"
    # make .vrt out of each variable's HDFs
    # ATTENTION: the second argument is not contained with quotation marks
    # Get the first (and presumably only) HDF file in the folder
    # Collect the list of HDFs for the year
    # Construct output .vrt path
    vrt_path="${cache}/${var}/${yr}.vrt"

    # Enable nullglob to handle empty glob patterns properly
    shopt -s nullglob
    
    # Collect the list of HDFs for the year
    hdf_files=(${geotiffDir}/${var}/${yrFormatted}/*.hdf)
    
    # Disable nullglob after use
    shopt -u nullglob

    # Debug: Print what we found
    echo "🔍 Looking for HDF files in: ${geotiffDir}/${var}/${yrFormatted}/"
    echo "🔍 Current working directory: $(pwd)"
    echo "🔍 Running as user: $(whoami)"
    echo "🔍 Script permissions: $(ls -la "$0" 2>/dev/null | awk '{print $1, $3, $4}' || echo "Cannot check")"
    echo "🔍 Directory permissions: $(ls -la "${geotiffDir}/${var}/${yrFormatted}/" 2>/dev/null | head -2 | tail -1 | awk '{print $1, $3, $4}' || echo "Cannot access directory")"
    echo "🔍 Number of HDF files found: ${#hdf_files[@]}"
    if [ ${#hdf_files[@]} -gt 0 ]; then
      echo "🔍 First HDF file: ${hdf_files[0]}"
      echo "🔍 First HDF file permissions: $(ls -la "${hdf_files[0]}" 2>/dev/null | awk '{print $1, $3, $4}' || echo "Cannot stat file")"
    fi

    # Check if HDF files exist
    if [ ${#hdf_files[@]} -eq 0 ]; then
      echo "❌ No HDF files found for ${yrFormatted}"
      
      # Try alternative method using find
      echo "🔍 Trying alternative search with find command..."
      mapfile -t hdf_files_alt < <(find "${geotiffDir}/${var}/${yrFormatted}/" -name "*.hdf" -type f 2>/dev/null)
      
      if [ ${#hdf_files_alt[@]} -gt 0 ]; then
        echo "🔍 Found ${#hdf_files_alt[@]} HDF files with find command"
        hdf_files=("${hdf_files_alt[@]}")
      else
        echo "❌ Still no HDF files found, skipping ${yrFormatted}"
        continue
      fi
    fi
    
    if [ ${#hdf_files[@]} -gt 0 ]; then
      echo "🔄 About to run gdalbuildvrt with ${#hdf_files[@]} HDF files"
      
      # Check file accessibility and permissions
      echo "🔍 Checking file accessibility..."
      accessible_files=()
      for hdf_file in "${hdf_files[@]}"; do
        if [ -r "$hdf_file" ]; then
          accessible_files+=("$hdf_file")
          echo "✅ Can read: $hdf_file"
        else
          echo "❌ Cannot read: $hdf_file"
          ls -la "$hdf_file" 2>/dev/null || echo "   File doesn't exist or no permissions to stat"
        fi
      done
      
      if [ ${#accessible_files[@]} -eq 0 ]; then
        echo "❌ No accessible HDF files found! Script cannot read any files."
        continue
      fi
      
      echo "🔍 Using ${#accessible_files[@]} accessible files out of ${#hdf_files[@]} total"
      
      # Test if gdalbuildvrt is accessible and working
      echo "🔍 Testing gdalbuildvrt availability..."
      if command -v gdalbuildvrt >/dev/null 2>&1; then
        echo "✅ gdalbuildvrt found in PATH"
        gdalbuildvrt --help >/dev/null 2>&1 && echo "✅ gdalbuildvrt help works" || echo "❌ gdalbuildvrt help failed"
        
        # Test HDF4 support in GDAL
        echo "🔍 Testing HDF4 support in GDAL..."
        hdf4_test_output=$(gdalinfo "$first_hdf" 2>&1)
        if echo "$hdf4_test_output" | grep -q "not recognized as being in a supported file format"; then
          echo "❌ GDAL does not have HDF4 support!"
          echo "📋 Error details:"
          echo "$hdf4_test_output" | grep -E "(ERROR|not recognized|plugin.*not available|install.*libgdal-hdf4)"
          echo ""
          echo "� Current conda environment: ${CONDA_DEFAULT_ENV:-"(not set)"}"
          echo "🔍 Current Python: $(which python)"
          echo "🔍 Current gdalinfo: $(which gdalinfo)"
          echo ""
          
          # Try to automatically activate the correct environment
          echo "🔄 Attempting to activate conda environment with HDF4 support..."
          
          # Check if conda is available
          if command -v conda >/dev/null 2>&1; then
            # Try to activate data-and-plotting environment
            if conda info --envs | grep -q "data-and-plotting"; then
              echo "🔄 Found 'data-and-plotting' environment, activating..."
              eval "$(conda shell.bash hook)"
              conda activate data-and-plotting
              
              # Test again after activation
              echo "🔍 Re-testing HDF4 support after environment activation..."
              hdf4_retest_output=$(gdalinfo "$first_hdf" 2>&1)
              if echo "$hdf4_retest_output" | grep -q "Driver: HDF4"; then
                echo "✅ SUCCESS! HDF4 support now available after activating data-and-plotting"
                echo "🔍 New gdalinfo location: $(which gdalinfo)"
              else
                echo "❌ Still no HDF4 support after activating data-and-plotting"
                echo "🔧 Manual steps required:"
                echo "   1. conda activate data-and-plotting"
                echo "   2. conda install -c conda-forge libgdal-hdf4"
                echo "   3. Re-run this script"
                exit 1
              fi
            else
              echo "❌ 'data-and-plotting' environment not found"
              echo "🔧 Manual steps required:"
              echo "   1. Create environment: conda create -n data-and-plotting"
              echo "   2. conda activate data-and-plotting" 
              echo "   3. conda install -c conda-forge gdal libgdal-hdf4"
              echo "   4. Re-run this script"
              exit 1
            fi
          else
            echo "❌ conda command not available"
            echo "� Please install conda/miniconda and set up HDF4 support manually"
            exit 1
          fi
        elif echo "$hdf4_test_output" | grep -q "Driver: HDF4"; then
          echo "✅ GDAL has HDF4 support - can read MODIS files!"
        else
          echo "⚠️  Unknown GDAL HDF4 status - proceeding with caution"
          echo "📋 gdalinfo output preview:"
          echo "$hdf4_test_output" | head -5
        fi
      else
        echo "❌ gdalbuildvrt not found in PATH"
        echo "🔍 PATH: $PATH"
        echo "🔧 Make sure GDAL is installed and activate the correct conda environment"
        exit 1
      fi
      
      # Check HDF subdatasets
      echo "🔍 Examining HDF subdatasets..."
      first_hdf="${accessible_files[0]}"
      
      # Show subdataset section of gdalinfo output for debugging
      echo "🔍 Subdataset section from gdalinfo:"
      gdalinfo "$first_hdf" | sed -n '/^Subdatasets:/,/^Corner Coordinates:/p' | head -20
      echo "🔍 ======================"
      
      # Extract subdatasets using the correct format
      echo "🔍 Extracting subdatasets..."
      
      # Method 1: Look for SUBDATASET_1_NAME specifically
      subdataset_1=$(gdalinfo "$first_hdf" | grep "^  SUBDATASET_1_NAME=" | cut -d'=' -f2)
      echo "🔍 Method 1 result: '$subdataset_1'"
      
      # Show all available subdatasets for reference
      echo "🔍 All available subdatasets:"
      gdalinfo "$first_hdf" | grep "^  SUBDATASET_.*_NAME="
      
      if [ -n "$subdataset_1" ]; then
        echo "🔍 Using subdataset 1: $subdataset_1"
        
        # Create array of subdataset paths for all HDF files
        subdataset_files=()
        for hdf_file in "${accessible_files[@]}"; do
          # Extract subdataset 1 for each HDF file
          subdataset_path=$(gdalinfo "$hdf_file" | grep "^  SUBDATASET_1_NAME=" | cut -d'=' -f2)
          
          if [ -n "$subdataset_path" ]; then
            # Remove any leading/trailing whitespace
            subdataset_path=$(echo "$subdataset_path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            subdataset_files+=("$subdataset_path")
            echo "🔍 Added subdataset: $subdataset_path"
          else
            echo "❌ Could not extract subdataset from: $hdf_file"
          fi
        done
        
        echo "🔍 Created ${#subdataset_files[@]} subdataset references"
      else
        echo "❌ Could not find SUBDATASET_1_NAME in HDF file"
        echo "🔍 Let's try a fallback approach - using the HDF file directly"
        subdataset_files=("${accessible_files[@]}")
        echo "🔍 Using ${#subdataset_files[@]} HDF files directly"
      fi
      
      # Check if output directory is writable
      if [ ! -w "$(dirname "$vrt_path")" ]; then
        echo "❌ Cannot write to output directory: $(dirname "$vrt_path")"
        ls -la "$(dirname "$vrt_path")" 2>/dev/null || echo "   Directory doesn't exist"
        continue
      fi
      
      echo "🔄 Running: gdalbuildvrt -overwrite \"$vrt_path\" [${#subdataset_files[@]} subdatasets] -resolution highest"

      # Run gdalbuildvrt with subdataset references (no -sd flag needed)
      gdal_output=$(gdalbuildvrt -overwrite "$vrt_path" "${subdataset_files[@]}" -resolution highest 2>&1)
      gdal_exit_code=$?
      
      if [ $gdal_exit_code -eq 0 ]; then
        # Check if VRT was created
        if [ -f "$vrt_path" ]; then
          echo "✅ Successfully created $vrt_path"
          
          # reproject .vrt to the standard EPSG:4326 projection
          echo "🔄 Reprojecting VRT to EPSG:$crs"
          gdalwarp_output=$(gdalwarp -of VRT -t_srs "EPSG:$crs" "${cache}/${var}/${yr}.vrt" "${cache}/${var}/${yr}_${crs}.vrt" 2>&1)
          gdalwarp_exit_code=$?
          
          if [ $gdalwarp_exit_code -eq 0 ]; then
            if [ -f "${cache}/${var}/${yr}_${crs}.vrt" ]; then
              echo "✅ .vrt file for $var in $yr is created under ${cache}/${var}/${yr}_${crs}.vrt"
            else
              echo "❌ Failed to create reprojected VRT: ${cache}/${var}/${yr}_${crs}.vrt"
            fi
          else
            echo "❌ gdalwarp command failed for ${cache}/${var}/${yr}.vrt"
            echo "📋 gdalwarp error output: $gdalwarp_output"
          fi
        else
          echo "❌ VRT file was not created: $vrt_path"
        fi
      else
        echo "❌ gdalbuildvrt command failed with exit code: $gdal_exit_code"
        echo "📋 gdalbuildvrt error output: $gdal_output"
      fi
    fi
  done
done

# subset and produce stats if needed
echo "$(logDate)$(basename $0): subsetting HDFs in GeoTIFF format under $outputDir"
# for each given year
for var in "${variables[@]}"; do
  mkdir -p ${outputDir}/${var}  
  # for each year 
  for yr in "${yearsRange[@]}"; do
    # subset based on lat and lon values
    if [[ "$printGeotiff" == "true" ]]; then
      subset_geotiff "${cache}/${var}/${yr}_${crs}.vrt" "${outputDir}/${var}/${prefix}${yr}.tif"
    elif [[ "$printGeotiff" == "false" ]]; then
      subset_geotiff "${cache}/${var}/${yr}_${crs}.vrt" "${cache}/${var}/${prefix}${yr}.tif"
    fi
  done
done

## make R renv project directory
if [[ -n "$shapefile" ]] && [[ -n $stats ]]; then
  echo "$(logDate)$(basename $0): Extracting stats under $outputDir"
  mkdir -p "$cache/r-virtual-env/"
  ## make R renv in $cache
  virtualEnvPath="$cache/r-virtual-env/"
  cp "${gistoolPath}/etc/renv/renv.lock" "$virtualEnvPath"

  for var in "${variables[@]}"; do
    # extract given stats for each variable

    for yr in "${yearsRange[@]}"; do
      # raster file path based on $printGeotiff value
      if [[ "$printGeotiff" == "true" ]]; then
        rasterPath="${outputDir}/${var}/${prefix}${yr}.tif"
      elif [[ "$printGeotiff" == "false" ]]; then
        rasterPath="${cache}/${var}/${prefix}${yr}.tif"
      fi

      ## make the temporary directory for installing r packages
      tempInstallPath="$cache/r-packages"
      mkdir -p "$tempInstallPath"
      export R_LIBS_USER="$tempInstallPath"

      ## build renv and create stats
    Rscript "${gistoolPath}/etc/scripts/stats.R" \
      "$tempInstallPath" \
      "$exactextractrCache" \
      "$renvPackagePath" \
	    "$virtualEnvPath" \
	    "$virtualEnvPath" \
	    "${virtualEnvPath}/renv.lock" \
	    "$rasterPath" \
	    "$shapefile" \
	    "$outputDir/${var}/${prefix}stats_${var}_${yr}.csv" \
	    "$stats" \
	    "$includeNA" \
	    "$quantiles" \
	    "$fid" >> "${outputDir}/${var}/${prefix}stats_${var}_${yr}.log" 2>&1;
    done
  done
fi

# produce stats if required
mkdir -p "$HOME/empty_dir" 
echo "$(logDate)$(basename $0): deleting temporary files from $cache"
# rsync --quiet -aP --delete "$HOME/empty_dir/" "$cache"
# rm -r "$cache"
echo "$(logDate)$(basename $0): temporary files from $cache are removed"
echo "$(logDate)$(basename $0): results are produced under $outputDir"


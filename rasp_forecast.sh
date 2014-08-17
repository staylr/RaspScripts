#!/bin/bash
# Run RASP, copy the output to an S3 bucket.
set -x
shutdown=false
archive=false
s3bucket=

rundate=`date '+%F_%T%Z'`
logfile=/tmp/rasp.$rundate.log
runhour=`date '+%H'`
archive_date=
archive_year=

exec &>$logfile

GETOPT=`getopt -o sb --long shutdown,s3bucket:,archive -n 'rasp_forecast.sh' -- "$@"`
eval set -- "$GETOPT"

while true
do
	case "$1" in
		-s | --shutdown) shutdown=true; shift ;;
		-a | --archive) archive=true; shift ;;
		-b | --s3bucket) s3bucket="$2"; shift 2 ;;
		--) shift; break ;;
		*) break ;;
	esac
done

if [[ "$s3bucket" == "" ]]
then
	echo "Usage: rasp_forecast.sh [--shutdown] [--archive] --s3bucket output_s3bucket regions ..." 1>&2
	exit 1
fi

if [[ "$runhour" -gt 12 ]]
then
	archive_date=`date --date=tomorrow '+%Y%m%d'`
	archive_year=`date --date=tomorrow '+%Y'`
else
	archive_date=`date '+%Y%m%d'`
	archive_year=`date '+%Y'`
fi

./umount.drjack

for region in "$@"
do
	date
	echo "Processing reegion $region"

	windowed_run=false

	forecastregion="$region"

	if [[ "$forecastregion" == "VICTORIA_NE" || \
			"$forecastregion" == "MELBOURNE" || \
			"$forecastregion" == "GRAMPIANS" || \
			"$forecastregion" == "BUNYAN_WAVE" ]]
	then
		windowed_run=true
	fi

	if [[ "$forecastregion" == "BUNYAN_WAVE" ]]
	then
		# XXX Pick up the parameters for the windowed region.
		# sudo cp $BASEDIR/RASP/RUN/rasp.run.parameters.BUNYAN_PM $BASEDIR/RASP/RUN/rasp.run.parameters.BUNYAN
		forecastregion = "BUNYAN"
	fi

	if [[ ! -f "$BASEDIR/RASP/RUN/rasp.run.parameters.$forecastregion" ]]
	then
		echo "Run parameters not found for $forecastregion" 1>&2
		exit 1
	fi	

 	rundate=`date '+%F_%T%Z'`
	progress_file="/tmp/progress.$$.txt"

	echo "Processing for $region on `uname -n` at $rundate" > "$progress_file"
	s3cmd sync "$progress_file" "$s3bucket/PROGRESS/$region.START.$rundate.txt"

	# Runs out of disk space/memory if these aren't cleared between regions.
	./reset.overlay.sh

	pushd .
	cd $BASEDIR/RASP/RUN
	./run.rasp "$forecastregion"
	popd

	s3cmd sync "$BASEDIR"/RASP/RUN/rasp.${forecastregion,,}.printout "$s3bucket/SAVED_LOGFILES/"
	s3cmd sync "$BASEDIR"/RASP/RUN/rasp.${forecastregion,,}.stderr "$s3bucket/SAVED_LOGFILES/"
	s3cmd sync "$BASEDIR/WRF/WRFSI/DOMAINS/$forecastregion/log/" "$s3bucket/SAVED_LOGFILES/$region/"

	s3cmd sync "$s3bucket/$forecastregion/FCST/" "$s3bucket/${forecastregion}-1/FCST/"
	s3cmd sync "$BASEDIR/RASP/RUN/OUT/$forecastregion/" "$s3bucket/$forecastregion/FCST/"

	if [[ "$archive" == "true" ]]
	then
		s3cmd sync "$BASEDIR/RASP/RUN/OUT/$forecastregion/" "$s3bucket/ARCHIVE/$forecastregion/$archive_year/$archive_date/"
		s3cmd sync "$BASEDIR/WRF/WRFV2/RASP/$forecastregion"/wrfout_d02_* "$s3bucket/ARCHIVE/$forecastregion/$archive_year/$archive_date/"
	fi

	if [[ "$windowed_run" == "true" ]]
	then
		s3cmd sync "$s3bucket/${forecastregion}-WINDOW/FCST/" "$s3bucket/${forecastregion}-WINDOW-1/FCST/"
		s3cmd sync "$BASEDIR/RASP/RUN/OUT/${forecastregion}-WINDOW/" "$s3bucket/${forecastregion}-WINDOW/FCST/"

		if [[ "$archive" == "true" ]]
		then
			s3cmd sync "$BASEDIR/RASP/RUN/OUT/${forecastregion}-WINDOW/" "$s3bucket/ARCHIVE/${forecastregion}-WINDOW/$archive_year/$archive_date/"
			s3cmd sync "$BASEDIR/WRF/WRFV2/RASP/${forecastregion}-WINDOW"/wrfout_d03_* "$s3bucket/ARCHIVE/${forecastregion}-WINDOW/$archive_year/$archive_date/"
		fi
	fi

	# XXX Detect error.
 	enddate=`date '+%F_%T%Z'`
	echo "Finished processing for $region on `uname -n` at $enddate" > "$progress_file"
	s3cmd sync "$progress_file" "$s3bucket/PROGRESS/$region.DONE.$rundate.txt"
	rm "$progress_file"
done

echo "All regions processed"


if [[ "$shutdown" == "true" ]]
then
	echo `date` ": shutting down in 1 minute"
	sudo shutdown -h +1 &
fi

exec 1>&-
exec 2>&-

s3cmd sync "$logfile" "$s3bucket/SAVED_LOGFILES/"


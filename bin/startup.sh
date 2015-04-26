#!/usr/bin/env bash

fullpath=`readlink -f $0`
binpath=`dirname $fullpath`
cd $binpath/../
NVC_HOME=`pwd`

echo "NVC_HOME=${NVC_HOME}"

echo "Start scraper....."
cd ./scraper
jruby -S bundle exec jruby ./scraper.rb 
ret=$?


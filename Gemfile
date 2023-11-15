source "http://rubygems.org"

platform :ruby do
  gem "bson_ext"
  gem "je", :group => :linux
end

platform :jruby do
  gem "bson"
end

gem "json", ">= 2.3.0"
gem "mechanize", ">= 2.7.5"
gem "mongo"
gem "nokogiri", ">= 1.11.4"
gem "bunny"
gem "march_hare"
gem "celluloid-io"

group :test do
  gem "rake"
  gem "rspec"
  gem "codeclimate-test-reporter", ">= 0.4.8", require: nil
end

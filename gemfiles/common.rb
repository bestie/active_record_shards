# frozen_string_literal: true

source 'https://rubygems.org'

gemspec path: Bundler.root.to_s.sub('/gemfiles', '')

group :test do
  gem 'pry-byebug', platforms: [:mri]
end

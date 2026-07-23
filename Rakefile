# frozen_string_literal: true

require_relative 'app'

namespace :cache do
  desc 'Fetch or refresh the full REST Countries cache'
  task :warm do
    WorldFlagApp.new!.send(:countries)
  end

  desc 'Remove stale or unsupported REST Countries cache files'
  task :prune do
    now = Time.now
    full_cache = File.join(CACHE_COUNTRIES, COUNTRIES_CACHE_FILE)
    current_list_caches = [full_cache]

    Dir.glob(File.join(CACHE_COUNTRIES, '*_v5.json')).each do |path|
      FileUtils.rm_f(path)
    end

    Dir.glob(File.join(CACHE_COUNTRIES, 'all_v5*.json')).each do |path|
      next if current_list_caches.include?(path)

      FileUtils.rm_f(path)
    end

    Dir.glob(File.join(CACHE_COUNTRIES, '*.lock')).each do |path|
      FileUtils.rm_f(path) if File.mtime(path) < now - CACHE_TTL_API
    end
  end
end

#!/usr/bin/env ruby
# Renders every repo's stubs from fleet.json and asserts they are not just
# parseable but STRUCTURALLY right.
#
# CI already parses templates with __PLACEHOLDER__ -> "x". That check is
# synthetic: it never sees a real fleet.json value, so it cannot catch a
# placeholder that renders wrong for a particular repo's config, and it cannot
# catch a value landing in the wrong place. Both have happened. A skill-path
# pin rendered outside the `with:` block still parses — YAML does not care —
# and the only thing standing between that and a broken release was a human
# reading a diff.
#
# Usage: ruby scripts/validate-render.rb
require 'yaml'
require 'json'
require 'tmpdir'
require 'open3'

HERE  = File.expand_path('..', __dir__)
fleet = JSON.parse(File.read(File.join(HERE, 'fleet.json')))
defaults = fleet['defaults']
repos = fleet['repos']
entries = repos.is_a?(Hash) ? repos.map { |k, v| [k, v] } : repos.map { |e| [e['repo'], e] }

def cfg(entry, defaults, key)
  v = entry[key]
  (v.nil? || v.to_s.empty?) ? defaults[key].to_s : v.to_s
end

failures = []
checked  = 0

entries.each do |repo, entry|
  Dir.mktmpdir do |dir|
    out, status = Open3.capture2e('bash', File.join(HERE, 'scripts/rollout.sh'), repo, '--render', dir)
    unless status.success?
      failures << "#{repo}: render failed\n#{out.lines.last(3).join}"
      next
    end

    Dir.glob(File.join(dir, '*.yml')).sort.each do |f|
      name = File.basename(f)
      src  = File.read(f)
      checked += 1

      # 1. A placeholder that survived rendering means a template gained a token
      #    nothing wires up — it would ship literally into a consumer repo.
      if (left = src.scan(/__[A-Z_]+__/).uniq).any?
        failures << "#{repo}/#{name}: unrendered placeholder(s) #{left.join(', ')}"
        next
      end

      begin
        doc = YAML.load(src)
      rescue => e
        failures << "#{repo}/#{name}: does not parse — #{e.message.lines.first.strip}"
        next
      end

      # 2. Psych parses the `on:` key as boolean true (YAML 1.1). Accept either.
      unless doc.is_a?(Hash) && (doc.key?('on') || doc.key?(true)) && doc.key?('jobs')
        failures << "#{repo}/#{name}: missing `on:` or `jobs:`"
        next
      end

      case name
      when 'release-please.yml'
        want  = cfg(entry, defaults, 'skill_path')
        steps = doc.dig('jobs', 'publish', 'steps') || []
        # The pin must live INSIDE a step's `with:` — the failure that started
        # this check was a pin sitting at column 0, structurally outside it.
        got = steps.map { |s| s.is_a?(Hash) ? s.dig('with', 'skill-path') : nil }.compact
        if want.empty?
          bad = got.reject { |g| g.nil? || g.to_s.strip.empty? }
          failures << "#{repo}/#{name}: skill-path #{bad.inspect} rendered but fleet.json records none" if bad.any?
        elsif !got.map(&:to_s).include?(want)
          failures << "#{repo}/#{name}: skill-path not inside a step's with: — wanted #{want.inspect}, found #{got.inspect}"
        end

      when 'ci.yml'
        want = cfg(entry, defaults, 'test_command')
        got  = doc.dig('jobs', 'ci', 'with', 'test-command').to_s
        failures << "#{repo}/#{name}: test-command #{got.inspect} != fleet.json #{want.inspect}" unless got == want

      when 'claude.yml'
        uses = doc.dig('jobs', 'claude', 'uses').to_s
        unless uses.include?('reusable-claude.yml')
          failures << "#{repo}/#{name}: job does not call reusable-claude.yml (got #{uses.inspect})"
        end
      end
    end
  end
end

if failures.empty?
  puts "rendered OK — #{checked} files across #{entries.size} repos"
else
  warn "RENDER VALIDATION FAILED (#{failures.size})"
  failures.each { |f| warn "  - #{f}" }
  exit 1
end

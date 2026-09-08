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

# Mirrors rollout.sh's jq `($r[$key] // .defaults[$key] // "")` EXACTLY.
# jq's `//` falls back only on null (or false) — an explicit "" in a repo entry
# is a value and wins. Treating "" as absent here would make this validator
# expect the default while rollout.sh rendered empty, i.e. a RENDER VALIDATION
# FAILED for a fleet.json that is perfectly correct. Two implementations of one
# lookup have to agree on the edge, or the checker becomes the thing that lies.
def cfg(entry, defaults, key)
  v = entry[key]
  v.nil? ? defaults[key].to_s : v.to_s
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

    # `**/*` and dotfile-prefixed directories: the stage is repo-shaped now, so
    # the workflow stubs sit under .github/workflows/ and the repo-config stubs
    # under .github/ and the root. A flat '*.yml' glob silently checked NOTHING
    # once the layout changed — the validator would have gone green on an
    # entirely unrendered fleet.
    Dir.glob(File.join(dir, '**', '*'), File::FNM_DOTMATCH).select { |f| File.file?(f) }.sort.each do |f|
      rel  = f.sub(%r{\A#{Regexp.escape(dir)}/}, '')
      name = File.basename(f)
      src  = File.read(f)
      checked += 1

      # 1. A placeholder that survived rendering means a template gained a token
      #    nothing wires up — it would ship literally into a consumer repo.
      if (left = src.scan(/__[A-Z_]+__/).uniq).any?
        failures << "#{repo}/#{rel}: unrendered placeholder(s) #{left.join(', ')}"
        next
      end

      # release-please-config.json is JSON, and its failure mode is quiet:
      # release-please skips a repo whose config does not parse rather than
      # failing, so a malformed render would show up as a repo that simply
      # stops cutting releases.
      if name.end_with?('.json')
        begin
          cfgdoc = JSON.parse(src)
        rescue => e
          failures << "#{repo}/#{rel}: does not parse as JSON — #{e.message.lines.first.strip}"
          next
        end

        if name == 'release-please-config.json'
          pkg = cfgdoc.dig('packages', '.') || {}
          want_name = cfg(entry, defaults, 'package_name')
          if pkg['package-name'].to_s != want_name
            failures << "#{repo}/#{rel}: package-name #{pkg['package-name'].inspect} != fleet.json #{want_name.inspect}"
          end
          # The release policy is the reason this file is templated at all: 8
          # repos had drifted to no changelog-sections whatsoever, which makes
          # every commit type invisible to the changelog.
          types  = (pkg['changelog-sections'] || []).map { |x| x['type'] }
          hidden = (pkg['changelog-sections'] || []).select { |x| x['hidden'] }.map { |x| x['type'] }
          missing = %w[feat fix perf revert refactor docs test build ci chore] - types
          failures << "#{repo}/#{rel}: changelog-sections missing #{missing.join(', ')}" if missing.any?
          wrong = %w[ci chore test build] - hidden
          failures << "#{repo}/#{rel}: #{wrong.join(', ')} must be hidden from the changelog" if wrong.any?
          leaked = %w[feat fix] & hidden
          failures << "#{repo}/#{rel}: #{leaked.join(', ')} must NOT be hidden" if leaked.any?
          # Every version file fleet.json records has to actually land in the
          # list; a dropped one means release-please stops stamping it and the
          # published version silently disagrees with the tag.
          extra = (pkg['extra-files'] || []).select { |x| x.is_a?(String) }
          cfg(entry, defaults, 'version_files').split(',').reject(&:empty?).each do |vf|
            failures << "#{repo}/#{rel}: version file #{vf.inspect} missing from extra-files" unless extra.include?(vf)
          end
        end
        next
      end

      begin
        doc = YAML.load(src)
      rescue => e
        failures << "#{repo}/#{rel}: does not parse — #{e.message.lines.first.strip}"
        next
      end

      # 2. Psych parses the `on:` key as boolean true (YAML 1.1). Accept either.
      #    Only WORKFLOW stubs have on:/jobs: — .github/dependabot.yml and
      #    .github/release.yml are plain config and must be exempted, or every
      #    repo fails on two files that are perfectly correct.
      if rel.start_with?('.github/workflows/')
        unless doc.is_a?(Hash) && (doc.key?('on') || doc.key?(true)) && doc.key?('jobs')
          failures << "#{repo}/#{rel}: missing `on:` or `jobs:`"
          next
        end
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
          failures << "#{repo}/#{rel}: skill-path #{bad.inspect} rendered but fleet.json records none" if bad.any?
        elsif !got.map(&:to_s).include?(want)
          failures << "#{repo}/#{rel}: skill-path not inside a step's with: — wanted #{want.inspect}, found #{got.inspect}"
        end

      when 'ci.yml'
        want = cfg(entry, defaults, 'test_command')
        got  = doc.dig('jobs', 'ci', 'with', 'test-command').to_s
        failures << "#{repo}/#{rel}: test-command #{got.inspect} != fleet.json #{want.inspect}" unless got == want

      when 'pr-auto-review.yml'
        want = cfg(entry, defaults, 'rereview_on_push')
        got  = doc.dig('jobs', 'review', 'with', 'rereview_on_push')
        if want.empty?
          # Assert on the SOURCE, not just the parsed doc. A bare
          # `rereview_on_push:` left behind by a broken drop-line rule parses
          # to nil, so a `got.nil?` check alone would pass while every repo
          # shipped a line meaning "explicitly null" instead of "unset".
          if src =~ /^\s*rereview_on_push:/
            failures << "#{repo}/#{rel}: renders a rereview_on_push line but fleet.json records none"
          end
        elsif got.to_s != want
          failures << "#{repo}/#{rel}: rereview_on_push #{got.inspect} != fleet.json #{want.inspect} (must sit inside the review job's with:)"
        end

      when 'dependabot.yml'
        # The vitest split deadlock, pinned. @vitest/coverage-v8 must be listed
        # by EXACT name: dependabot scores group patterns by specificity and
        # the wildcard "@vitest/*" (94) loses the package to the pattern-less
        # dev-dependencies group (500), which on a major cannot take it either
        # — so it escapes into its own PR and the peer-locked pair deadlocks on
        # ERESOLVE. The exact name scores 1000 and nothing outbids it.
        eco = (doc['updates'] || []).map { |u| u['package-ecosystem'] }
        unless eco.include?('github-actions')
          failures << "#{repo}/#{rel}: no github-actions ecosystem — pinned action versions would stop moving"
        end
        npm = (doc['updates'] || []).find { |u| u['package-ecosystem'] == 'npm' }
        if npm
          pats = npm.dig('groups', 'vitest', 'patterns') || []
          unless pats.include?('@vitest/coverage-v8')
            failures << "#{repo}/#{rel}: vitest group does not pin @vitest/coverage-v8 by exact name"
          end
        end

      when 'claude.yml'
        uses = doc.dig('jobs', 'claude', 'uses').to_s
        unless uses.include?('reusable-claude.yml')
          failures << "#{repo}/#{rel}: job does not call reusable-claude.yml (got #{uses.inspect})"
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

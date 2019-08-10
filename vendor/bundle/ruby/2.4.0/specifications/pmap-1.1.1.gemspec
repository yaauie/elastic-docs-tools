# -*- encoding: utf-8 -*-
# stub: pmap 1.1.1 ruby lib

Gem::Specification.new do |s|
  s.name = "pmap".freeze
  s.version = "1.1.1"

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib".freeze]
  s.authors = ["Bruce Adams".freeze, "Jake Goulding".freeze, "David Biehl".freeze]
  s.date = "2015-11-21"
  s.description = "Add parallel methods into Enumerable: pmap and peach".freeze
  s.email = ["bruce.adams@acm.org".freeze, "jake.goulding@gmail.com".freeze, "me@davidbiehl.com".freeze]
  s.homepage = "https://github.com/bruceadams/pmap".freeze
  s.licenses = ["Apache-2.0".freeze]
  s.rubygems_version = "2.7.7".freeze
  s.summary = "Add parallel methods into Enumerable: pmap and peach".freeze

  s.installed_by_version = "2.7.7" if s.respond_to? :installed_by_version

  if s.respond_to? :specification_version then
    s.specification_version = 4

    if Gem::Version.new(Gem::VERSION) >= Gem::Version.new('1.2.0') then
      s.add_development_dependency(%q<test-unit>.freeze, [">= 0"])
    else
      s.add_dependency(%q<test-unit>.freeze, [">= 0"])
    end
  else
    s.add_dependency(%q<test-unit>.freeze, [">= 0"])
  end
end

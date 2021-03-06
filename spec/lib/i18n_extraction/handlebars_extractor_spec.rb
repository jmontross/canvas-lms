#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

require File.expand_path(File.dirname(__FILE__) + '/../../spec_helper.rb')

describe I18nExtraction::HandlebarsExtractor do
  def extract(source, scope = 'asdf', options = {})
    scope_results = scope && (options.has_key?(:scope_results) ? options.delete(:scope_results) : true)

    extractor = I18nExtraction::HandlebarsExtractor.new
    extractor.process(source, scope)
    (scope_results ?
      scope.split(/\./).inject(extractor.translations) { |hash, s| hash[s] } :
      extractor.translations) || {}
  end

  context "keys" do
    it "should allow valid string keys" do
      extract('{{#t "foo"}}Foo{{/t}}').should eql({'foo' => "Foo"})
    end

    it "should disallow everything else" do
      lambda{ extract '{{#t "foo foo"}}Foo{{/t}}' }.should raise_error 'invalid translation key "foo foo" on line 1'
    end
  end

  context "well-formed-ness" do
    it "should make sure all #t calls are closed" do
      lambda{ extract "{{#t \"foo\"}}Foo{{/t}}\n{{#t \"bar\"}}...\nruh-roh\n" }.should raise_error /possibly unterminated #t call \(line 2/
    end
  end

  context "values" do
    it "should strip extraneous whitespace" do
      extract("{{#t \"foo\"}}\t Foo\n foo\r\n\ffoo!!! {{/t}}").should eql({'foo' => 'Foo foo foo!!!'})
    end
  end

  context "placeholders" do
    it "should allow simple placeholders" do
      extract('{{#t "foo"}}Hello {{user.name}}{{/t}}').should eql({'foo' => 'Hello %{user.name}'})
    end

    it "should disallow helpers or anything else" do
      lambda{ extract '{{#t "foo"}}Hello {{call a helper}}{{/t}}' }.should raise_error 'helpers may not be used inside #t calls (line 1)'
    end
  end

  context "wrappers" do
    it "should infer wrappers" do
      extract('{{#t "foo"}}Be sure to <a href="{{url}}">log in</a>. <b>Don\'t</b> you <b>dare</b> forget!!!{{/t}}').should eql({'foo' => 'Be sure to *log in*. **Don\'t** you **dare** forget!!!'})
    end

    it "should disallow any un-wrapper-ed html" do
      lambda{ extract '{{#t "foo"}}check out this pic: <img src="pic.gif">{{/t}}' }.should raise_error 'translation contains un-wrapper-ed markup (line 1). hint: use a placeholder'
    end
  end

  context "scoping" do
    it "should auto-scope relative keys to the current scope" do
      extract('{{#t "foo"}}Foo{{/t}}', 'asdf', :scope_results => false).should eql({'asdf' => {'foo' => "Foo"}})
    end

    it "should not auto-scope absolute keys" do
      extract('{{#t "#foo"}}Foo{{/t}}', 'asdf', :scope_results => false).should eql({'foo' => "Foo"})
    end
  end

  context "collisions" do
    it "should not let you reuse a key" do
      lambda{ extract '{{#t "foo"}}Foo{{/t}}{{#t "foo"}}foo{{/t}}' }.should raise_error 'cannot reuse key "asdf.foo"'
    end

    it "should not let you use a scope as a key" do
      lambda{ extract '{{#t "foo.bar"}}bar{{/t}}{{#t "foo"}}foo{{/t}}' }.should raise_error '"asdf.foo" used as both a scope and a key'
    end

    it "should not let you use a key as a scope" do
      lambda{ extract '{{#t "foo"}}foo{{/t}}{{#t "foo.bar"}}bar{{/t}}' }.should raise_error '"asdf.foo" used as both a scope and a key'
    end
  end
end

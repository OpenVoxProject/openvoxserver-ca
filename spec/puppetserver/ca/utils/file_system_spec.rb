require 'spec_helper'
require 'tmpdir'
require 'fileutils'

require 'puppetserver/ca/utils/file_system'

RSpec.describe Puppetserver::Ca::Utils::FileSystem do
  describe '.forcibly_symlink' do
    it 'creates a symlink without calling chown when not running as root' do
      Dir.mktmpdir do |tmpdir|
        source = File.join(tmpdir, 'new_cadir')
        link_target = File.join(tmpdir, 'old_cadir')
        FileUtils.mkdir_p(source)
        FileUtils.mkdir_p(link_target)

        allow(described_class.instance).to receive(:running_as_root?).and_return(false)
        expect(FileUtils).not_to receive(:chown)

        described_class.forcibly_symlink(source, link_target)

        expect(File.symlink?(link_target)).to be(true)
        expect(File.readlink(link_target)).to eq(source)
      end
    end

    it 'creates a symlink and calls chown when running as root' do
      Dir.mktmpdir do |tmpdir|
        source = File.join(tmpdir, 'new_cadir')
        link_target = File.join(tmpdir, 'old_cadir')
        FileUtils.mkdir_p(source)
        FileUtils.mkdir_p(link_target)

        allow(described_class.instance).to receive(:running_as_root?).and_return(true)
        allow(File).to receive(:stat).and_call_original

        source_info = instance_double(File::Stat, uid: 123, gid: 456)
        allow(File).to receive(:stat).with(source).and_return(source_info)
        expect(FileUtils).to receive(:chown).with(123, 456, link_target)

        described_class.forcibly_symlink(source, link_target)

        expect(File.symlink?(link_target)).to be(true)
      end
    end
  end

  describe '#write_file' do
    it 'writes the file without calling chown when not running as root' do
      Dir.mktmpdir do |tmpdir|
        path = File.join(tmpdir, 'test.pem')

        instance = described_class.instance
        allow(instance).to receive(:running_as_root?).and_return(false)
        expect(FileUtils).not_to receive(:chown)

        instance.write_file(path, 'test content', 0644)

        expect(File.read(path)).to include('test content')
      end
    end

    it 'writes the file and calls chown when running as root' do
      Dir.mktmpdir do |tmpdir|
        path = File.join(tmpdir, 'test.pem')

        instance = described_class.instance
        allow(instance).to receive(:running_as_root?).and_return(true)
        expect(FileUtils).to receive(:chown)

        instance.write_file(path, 'test content', 0644)
      end
    end
  end

  describe '#ensure_dir' do
    it 'creates the directory without calling chown when not running as root' do
      Dir.mktmpdir do |tmpdir|
        directory = File.join(tmpdir, 'newdir')

        instance = described_class.instance
        allow(instance).to receive(:running_as_root?).and_return(false)
        expect(FileUtils).not_to receive(:chown)

        instance.ensure_dir(directory)

        expect(File.directory?(directory)).to be(true)
      end
    end

    it 'creates the directory and calls chown when running as root' do
      Dir.mktmpdir do |tmpdir|
        directory = File.join(tmpdir, 'newdir')

        instance = described_class.instance
        allow(instance).to receive(:running_as_root?).and_return(true)
        expect(FileUtils).to receive(:chown)

        instance.ensure_dir(directory)

        expect(File.directory?(directory)).to be(true)
      end
    end
  end
end

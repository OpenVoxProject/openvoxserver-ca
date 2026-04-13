require 'spec_helper'
require 'puppetserver/ca/utils/file_system'

RSpec.describe Puppetserver::Ca::Utils::FileSystem do
  describe '.ensure_ownership' do
    let(:path) { '/some/path' }

    context 'when not running as root' do
      before do
        allow(described_class).to receive(:running_as_root?).and_return(false)
      end

      it 'does not change ownership' do
        expect(FileUtils).not_to receive(:chown)
        described_class.ensure_ownership(path)
      end
    end

    context 'when running as root' do
      before do
        allow(described_class).to receive(:running_as_root?).and_return(true)
      end

      it 'chowns to puppet when pe-puppet does not exist' do
        allow(described_class).to receive(:pe_puppet_exists?).and_return(false)

        expect(FileUtils).to receive(:chown).with('puppet', 'puppet', path)
        described_class.ensure_ownership(path)
      end

      it 'chowns to pe-puppet when pe-puppet exists' do
        allow(described_class).to receive(:pe_puppet_exists?).and_return(true)

        expect(FileUtils).to receive(:chown).with('pe-puppet', 'pe-puppet', path)
        described_class.ensure_ownership(path)
      end
    end
  end
end

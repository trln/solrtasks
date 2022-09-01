describe SolrTasks::Fetcher do
  let(:modern) { described_class.new('.', '9.0.0') }

  let(:archive) { described_class.new('.', '7.7.1') }


  context '#fetch_download_uri' do 
    it 'finds a modern version on a primary server' do
      expect(modern.send(:fetch_download_uri).to_s).not_to include('archive')
    end

	it 'finds an older version on an archive server' do
      expect(archive.send(:fetch_download_uri).host).to eq('archive.apache.org')
    end
  end
end


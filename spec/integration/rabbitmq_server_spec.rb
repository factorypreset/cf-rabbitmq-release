require 'spec_helper'

require 'json'
require 'ostruct'
require 'tempfile'

require 'httparty'

RSpec.describe 'RabbitMQ server configuration' do
  let(:rmq_host) { 'rmq/0' }

  let(:environment_settings) do
    stdout(bosh.ssh(rmq_host, 'sudo ERL_DIR=/var/vcap/packages/erlang/bin/ /var/vcap/packages/rabbitmq-server/bin/rabbitmqctl environment'))
  end

  let(:ssl_options) do
    stdout(bosh.ssh(rmq_host, "sudo ERL_DIR=/var/vcap/packages/erlang/bin/ /var/vcap/packages/rabbitmq-server/bin/rabbitmqctl eval 'application:get_env(rabbit, ssl_options).'"))
  end

  describe 'Defaults' do
    context 'set defaults' do
      before(:all) do
        bosh.redeploy do |manifest|
          rmq_properties = get_properties(manifest, 'rmq', 'rabbitmq-server')['rabbitmq-server']
          rmq_properties.delete('cluster_partition_handling')
          rmq_properties.delete('use_native_clustering_formation')
          rmq_properties.delete('disk_alarm_threshold')
          rmq_properties.delete('ssl')
        end
      end

      after(:all) do
        bosh.deploy(test_manifest)
      end

      it 'should be use pause_minority partition handling policy' do
        expect(environment_settings).to include('{cluster_partition_handling,pause_minority}')
      end

      it 'should have disk free limit set to "{mem_relative,0.4}" as default' do
        expect(environment_settings).to include('{disk_free_limit,{mem_relative,0.4}}')
      end

      it 'does not have SSL verification enabled and peer validation enabled' do
        expect(ssl_options).to include('{ok,[]}')
      end
    end
  end

  context 'when properties are set' do
    before(:all) do
      manifest = bosh.manifest
      @old_username = get_properties(manifest, 'rmq', 'rabbitmq-server')['rabbitmq-server']['administrators']['management']['username']
      @old_password = get_properties(manifest, 'rmq', 'rabbitmq-server')['rabbitmq-server']['administrators']['management']['password']

      @new_username = 'newusername'
      @new_password = 'newpassword'

      bosh.redeploy do |manifest|
        rmq_properties = get_properties(manifest, 'rmq', 'rabbitmq-server')['rabbitmq-server']
        rmq_properties['disk_alarm_threshold'] = '20000000'
        rmq_properties['cluster_partition_handling'] = 'pause_minority'
        rmq_properties['fd_limit'] = 350_000

        management_credentials = rmq_properties['administrators']['management']
        management_credentials['username'] = @new_username
        management_credentials['password'] = @new_password
      end
    end

    after(:all) do
      bosh.deploy(test_manifest)
    end

    it 'should have hard disk alarm threshold of 20 MB' do
      expect(environment_settings).to include('{disk_free_limit,20000000}')
    end

    it 'should be use pause_minority' do
      expect(environment_settings).to include('{cluster_partition_handling,pause_minority}')
    end

    it 'it can only access the management HTTP API with the new credentials' do
      manifest = bosh.manifest
      rabbitmq_api = get_properties(manifest, 'haproxy', 'route_registrar')['route_registrar']['routes'].first['uris'].first

      response = HTTParty.get("http://#{rabbitmq_api}/api/whoami", {:basic_auth => {:username => @new_username, :password => @new_password}})
      expect(response.code).to eq 200

      response = HTTParty.get("http://#{rabbitmq_api}/api/whoami", {:basic_auth => {:username => @old_username, :password => @old_password}})
      expect(response.code).to eq 401
    end
  end

  describe 'SSL' do
    context 'when is configured' do
      before(:all) do
        server_key = File.read(File.join(__dir__, '../..', '/spec/assets/server_key.pem'))
        server_cert = File.read(File.join(__dir__, '../..', '/spec/assets/server_certificate.pem'))
        ca_cert = File.read(File.join(__dir__, '../..', '/spec/assets/ca_certificate.pem'))

        bosh.redeploy do |manifest|
          rmq_properties = get_properties(manifest, 'rmq', 'rabbitmq-server')['rabbitmq-server']
          rmq_properties['ssl'] = Hash.new
          rmq_properties['ssl']['key'] = server_key
          rmq_properties['ssl']['cert'] = server_cert
          rmq_properties['ssl']['cacert'] = ca_cert
          rmq_properties['ssl']['versions'] = ['tlsv1.2','tlsv1.1', 'tlsv1']
        end
      end

      after(:all) do
        bosh.deploy(test_manifest)
      end

      it 'does not have SSL verification enabled' do
        expect(ssl_options).to include('{verify,verify_none}')
      end

      it 'does not have SSL peer validation enabled' do
        expect(ssl_options).to include('{fail_if_no_peer_cert,false}')
      end

      it 'has the right SSL verification depth option' do
        expect(ssl_options).to include('{depth,5}')
      end

      describe "TLS" do
        it 'should have TLS 1.0 enabled' do
          output = bosh.ssh(rmq_host, connect_using('tls1'))

          expect(stdout(output)).to include('BEGIN CERTIFICATE')
          expect(stdout(output)).to include('END CERTIFICATE')
        end

        it 'should have TLS 1.1 enabled' do
          output = bosh.ssh(rmq_host, connect_using('tls1_1'))

          expect(stdout(output)).to include('BEGIN CERTIFICATE')
          expect(stdout(output)).to include('END CERTIFICATE')
        end

        it 'should have TLS 1.2 enabled' do
          output = bosh.ssh(rmq_host, connect_using('tls1_2'))

          expect(stdout(output)).to include('BEGIN CERTIFICATE')
          expect(stdout(output)).to include('END CERTIFICATE')
        end

        def connect_using(tls_version)
          "openssl s_client -#{tls_version} -connect 127.0.0.1:5671"
        end
      end

      context 'when verification and validation is enabled' do
        before(:all) do
          bosh.redeploy do |manifest|
            rmq_ssl_properties = get_properties(manifest, 'rmq', 'rabbitmq-server')['rabbitmq-server']['ssl']
            rmq_ssl_properties['verify'] = true
            rmq_ssl_properties['verification_depth'] = 10
            rmq_ssl_properties['fail_if_no_peer_cert'] = true
          end
        end

        it 'has the right SSL verification options' do
          expect(ssl_options).to include('{verify,verify_peer}')
        end

        it 'has the right SSL verification depth option' do
          expect(ssl_options).to include('{depth,10}')
        end

        it 'has the right SSL peer options' do
          expect(ssl_options).to include('{fail_if_no_peer_cert,true}')
        end
      end
    end
  end

  describe 'load definitions' do
    let(:vhost) { 'foobar' }

    before(:each) do
      bosh.redeploy do |manifest|
        rmq_properties = get_properties(manifest, 'rmq', 'rabbitmq-server')['rabbitmq-server']
        rmq_properties['load_definitions'] = Hash.new
        rmq_properties['load_definitions']['vhosts'] = [{'name'=> vhost}]
      end
    end

    after(:each) do
      bosh.deploy(test_manifest)
    end

    it 'creates a vhost when vhost definition is provided' do
      creds = get_admin_creds
      response = get("#{rabbitmq_api_url}/vhosts/#{vhost}", creds['username'], creds['password'])

      expect(response['name']).to eq(vhost)
    end
  end

  describe 'when changing the cookie' do
    before(:each) do
      bosh.redeploy do |manifest|
        rmq_properties = get_properties(manifest, 'rmq', 'rabbitmq-server')['rabbitmq-server']
        rmq_properties['cookie'] = 'change-the-cookie'
      end
    end

    after(:each) do
      bosh.deploy(test_manifest)
    end

    it 'all the nodes come back' do
      creds = get_admin_creds
      nodes = get("#{rabbitmq_api_url}/nodes", creds['username'], creds['password'])

      expect(nodes.size).to eq(3)
      nodes.each do |node|
        expect(node['running']).to eq(true)

        applications = (node['applications'] || []).map{|app| app['name']}
        expect(applications).to include('rabbit')
        expect(applications).to include('rabbitmq_management')
      end
    end
  end
end

def get_admin_creds
  get_properties(bosh.manifest, 'rmq', 'rabbitmq-server')['rabbitmq-server']['administrators']['management']
end


def stdout(output)
  output['Tables'].first['Rows'].first['stdout']
end


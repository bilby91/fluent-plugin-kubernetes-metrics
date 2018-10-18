#
# Copyright 2018- Gimi Liang
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'time'

require 'fluent/plugin/input'
require 'kubeclient'
require 'multi_json'

module Fluent
  module Plugin
    class KubernetesMetricsInput < Fluent::Plugin::Input
      Fluent::Plugin.register_input('kubernetes_metrics', self)

      helpers :timer

      desc 'The tag of the event.'
      config_param :tag, :string, default: 'kubernetes.metrics.*'

      desc 'How often it pulls metrcs.'
      config_param :interval, :time, default: '15s'

      desc 'Path to a kubeconfig file points to a cluster the plugin should collect metrics from. Mostly useful when running fluentd outside of the cluster. When `kubeconfig` is set, `kubernetes_url`, `client_cert`, `client_key`, `ca_file`, `insecure_ssl`, `bearer_token_file`, and `secret_dir` will all be ignored.'
      config_param :kubeconfig, :string, default: nil

      desc 'URL of the kubernetes API server.'
      config_param :kubernetes_url, :string, default: nil

      desc 'Path to the certificate file for this client.'
      config_param :client_cert, :string, default: nil

      desc 'Path to the private key file for this client.'
      config_param :client_key, :string, default: nil

      desc 'Path to the CA file.'
      config_param :ca_file, :string, default: nil

      desc "If `insecure_ssl` is set to `true`, it won't verify apiserver's certificate."
      config_param :insecure_ssl, :bool, default: false

      desc 'Path to the file contains the API token. By default it reads from the file "token" in the `secret_dir`.'
      config_param :bearer_token_file, :string, default: nil

      desc "Path of the location where pod's service account's credentials are stored."
      config_param :secret_dir, :string, default: '/var/run/secrets/kubernetes.io/serviceaccount'

      desc 'Name of the node that this plugin should collect metrics from.'
      config_param :node_name, :string, default: nil

      desc 'Name of the nodes that this plugin should collect metrics from.'
      config_param :node_names, :array, default: [], value_type: :string

      desc 'The port that kubelet is listening to.'
      config_param :kubelet_port, :integer, default: 10_255

      desc 'Use the rest client to get the metrics from summary api on each kubelet'
      config_param :use_rest_client, :bool, default: true

      def configure(conf)
        super

        if @use_rest_client
          raise Fluentd::ConfigError, 'node_name is required' if @node_name.nil? || @node_name.empty?
        else
          raise Fluentd::ConfigError, 'node_names array is required' if @node_names.nil? || @node_names.empty? || (@node_names.length <= 0)
        end

        parse_tag
        initialize_client
      end

      def start
        super

        timer_execute :metric_scraper, @interval, &method(:scrape_metrics)
      end

      def close
        @watchers.each &:finish if @watchers
        super
      end

      private

      def parse_tag
        @tag_prefix, @tag_suffix = @tag.split('*') if @tag.include?('*')
      end

      def generate_tag(item_name)
        return @tag unless @tag_prefix

        [@tag_prefix, item_name, @tag_suffix].join
      end

      def init_with_kubeconfig(options = {})
        config = Kubeclient::Config.read @kubeconfig
        current_context = config.context

        @client = Kubeclient::Client.new(
          current_context.api_endpoint,
          current_context.api_version,
          options.merge(
            ssl_options: current_context.ssl_options,
            auth_options: current_context.auth_options
          )
        )
      end

      def init_without_kubeconfig(_options = {})
        # mostly borrowed from Fluentd Kubernetes Metadata Filter Plugin
        if @kubernetes_url.nil?
          # Use Kubernetes default service account if we're in a pod.
          env_host = ENV['KUBERNETES_SERVICE_HOST']
          env_port = ENV['KUBERNETES_SERVICE_PORT']
          if env_host && env_port
            @kubernetes_url = "https://#{env_host}:#{env_port}/api/"
          end
        end

        raise Fluent::ConfigError, 'kubernetes url is not set' unless @kubernetes_url

        # Use SSL certificate and bearer token from Kubernetes service account.
        if Dir.exist?(@secret_dir)
          secret_ca_file = File.join(@secret_dir, 'ca.cert')
          secret_token_file = File.join(@secret_dir, 'token')

          if @ca_file.nil? && File.exist?(secret_ca_file)
            @ca_file = secret_ca_file
          end

          if @bearer_token_file.nil? && File.exist?(secret_token_file)
            @bearer_token_file = secret_token_file
          end
        end

        ssl_options = {
          client_cert: @client_cert && OpenSSL::X509::Certificate.new(File.read(@client_cert)),
          client_key:  @client_key && OpenSSL::PKey::RSA.new(File.read(@client_key)),
          ca_file:     @ca_file,
          verify_ssl:  @insecure_ssl ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER
        }

        auth_options = {}
        auth_options[:bearer_token] = File.read(@bearer_token_file) if @bearer_token_file

        @client = Kubeclient::Client.new(
          @kubernetes_url, 'v1',
          ssl_options: ssl_options,
          auth_options: auth_options
        )

        begin
          @client.api_valid?
        rescue KubeException => kube_error
          raise Fluent::ConfigError, "Invalid Kubernetes API #{@api_version} endpoint #{@kubernetes_url}: #{kube_error.message}"
        end
      end

      def initialize_client
        if @use_rest_client
          initialize_rest_client
        else
          options = {
            timeouts: {
              open: 10,
              read: nil
            }
          }

          if @kubeconfig.nil?
            init_without_kubeconfig options
          else
            init_with_kubeconfig options
          end
        end
      end

      def initialize_rest_client
        env_host = @node_name
        env_port = 10_255 # 10255 is the readonly port of the kubelet from where we can fetch the metrics exposed by summary API

        if env_host && env_port
          @kubelet_url = "http://#{env_host}:#{env_port}/stats/summary"
        end

        log.info("Use URL #{@kubelet_url} for creating client to query kubelet summary api")
      end

      # This method is used to set the options for sending a request to the kubelet api
      def request_options
        options = { method: 'get', url: @kubelet_url }
        options
      end

      # @client.proxy_url only returns the url, but we need the resource, not just the url
      def summary_api(node)
        @summary_api =
          begin
            @client.discover unless @client.discovered
            @client.rest_client["/nodes/#{node}:#{@kubelet_port}/proxy/stats/summary"].tap do |endpoint|
              log.info("Use URL #{endpoint.url} for scraping metrics")
            end
          end
      end

      def parse_time(metric_time)
        Fluent::EventTime.from_time Time.iso8601(metric_time)
      end

      def underscore(camlcase)
        camlcase.gsub(/[A-Z]/) { |c| "_#{c.downcase}" }
      end

      def emit_uptime(tag:, start_time:, labels:)
        uptime = @scraped_at - Time.iso8601(start_time)
        router.emit generate_tag("#{tag}.uptime"), Fluent::EventTime.from_time(@scraped_at), labels.merge('value' => uptime)
      end

      def emit_cpu_metrics(tag:, metrics:, labels:)
        time = parse_time metrics['time']
        if usage_rate = metrics['usageNanoCores']
          router.emit generate_tag("#{tag}.cpu.usage_rate"), time, labels.merge('value' => usage_rate / 1_000_000)
        end
        if usage = metrics['usageNanoCores']
          router.emit generate_tag("#{tag}.cpu.usage"), time, labels.merge('value' => usage)
        end
      end

      def emit_memory_metrics(tag:, metrics:, labels:)
        time = parse_time metrics['time']
        %w[availableBytes usageBytes workingSetBytes rssBytes pageFaults majorPageFaults].each do |name|
          if value = metrics[name]
            router.emit generate_tag("#{tag}.memory.#{underscore name}"), time, labels.merge('value' => value)
          end
        end
      end

      def emit_network_metrics(tag:, metrics:, labels:)
        time = parse_time metrics['time']
        Array(metrics['interfaces']).each do |it|
          it_name = it['name']
          %w[rxBytes rxErrors txBytes txErrors].each do |metric_name|
            if value = it[metric_name]
              router.emit generate_tag("#{tag}.network.#{underscore metric_name}"), time, labels.merge('value' => value, 'interface' => it_name)
            end
          end
        end
      end

      def emit_fs_metrics(tag:, metrics:, labels:)
        time = parse_time metrics['time']
        %w[availableBytes capacityBytes usedBytes inodesFree inodes inodesUsed].each do |metric_name|
          if value = metrics[metric_name]
            router.emit generate_tag("#{tag}.#{underscore metric_name}"), time, labels.merge('value' => value)
          end
        end
      end

      def emit_node_rlimit_metrics(node_name, rlimit)
        time = parse_time rlimit['time']
        %w[maxpid curproc].each do |metric_name|
          next unless value = rlimit[metric_name]

          router.emit(generate_tag("node.runtime.imagefs.#{metric_name}"), time,
                      'value' => value,
                      'node' => node_name)
        end
      end

      def emit_system_container_metrics(node_name, container)
        tag = 'sys-container'
        labels = { 'node' => node_name, 'name' => container['name'] }
        emit_uptime tag: tag, start_time: container['startTime'], labels: labels
        emit_cpu_metrics tag: tag, metrics: container['cpu'], labels: labels
        emit_memory_metrics tag: tag, metrics: container['memory'], labels: labels
      end

      def emit_node_metrics(node)
        node_name = node['nodeName']
        tag = 'node'
        labels = { 'node' => node_name }

        unless node['startTime'].nil?
          emit_uptime tag: tag, start_time: node['startTime'], labels: labels
        end
        unless node['cpu'].nil?
          emit_cpu_metrics tag: tag, metrics: node['cpu'], labels: labels
        end
        unless node['memory'].nil?
          emit_memory_metrics tag: tag, metrics: node['memory'], labels: labels
        end
        unless node['network'].nil?
          emit_network_metrics tag: tag, metrics: node['network'], labels: labels
        end
        unless node['fs'].nil?
          emit_fs_metrics tag: "#{tag}.fs", metrics: node['fs'], labels: labels
        end
        unless node['runtime']['imageFs'].nil?
          emit_fs_metrics tag: "#{tag}.imagefs", metrics: node['runtime']['imageFs'], labels: labels
        end
        unless node['rlimit'].nil?
          emit_node_rlimit_metrics node_name, node['rlimit']
        end
        unless node['systemContainers'].nil?
          node['systemContainers'].each do |c|
            emit_system_container_metrics node_name, c
          end
          end
      end

      def emit_container_metrics(pod_labels, container)
        tag = 'container'
        labels = pod_labels.merge 'container-name' => container['name']
        emit_uptime tag: tag, start_time: container['startTime'], labels: labels
        emit_cpu_metrics tag: tag, metrics: container['cpu'], labels: labels
        emit_memory_metrics tag: tag, metrics: container['memory'], labels: labels
        emit_fs_metrics tag: "#{tag}.rootfs", metrics: container['rootfs'], labels: labels
        emit_fs_metrics tag: "#{tag}.logs", metrics: container['logs'], labels: labels
      end

      def emit_pod_metrics(node_name, pod)
        tag = 'pod'
        labels = pod['podRef'].transform_keys &'pod-'.method(:+)
        labels['node'] = node_name

        emit_uptime tag: tag, start_time: pod['startTime'], labels: labels
        emit_cpu_metrics tag: tag, metrics: pod['cpu'], labels: labels if pod['cpu']
        emit_memory_metrics tag: tag, metrics: pod['memory'], labels: labels if pod['memory']
        emit_network_metrics tag: tag, metrics: pod['network'], labels: labels
        emit_fs_metrics tag: "#{tag}.ephemeral-storage", metrics: pod['ephemeral-storage'], labels: labels
        Array(pod['volume']).each do |volume|
          emit_fs_metrics tag: "#{tag}.volume", metrics: volume, labels: labels.merge('name' => volume['name'])
        end
        Array(pod['containers']).each do |container|
          emit_container_metrics labels, container
        end
      end

      def emit_metrics(metrics)
        emit_node_metrics(metrics['node']) unless metrics['node'].nil?
        Array(metrics['pods']).each &method(:emit_pod_metrics).curry.call(metrics['node']['nodeName']) unless metrics['pods'].nil?
      end

      def scrape_metrics
        if @use_rest_client
          response = RestClient::Request.execute request_options
          handle_response(response)
        else
          @node_names.each do |node|
            response = summary_api(node).get(@client.headers)
            handle_response(response)
          end
        end
      end

      # This method is used to handle responses from the kubelet summary api
      def handle_response(response)
        # Checking response codes only for a successful GET request viz., 2XX codes
        if (response.code < 300) && (response.code > 199)
          @scraped_at = Time.now
          emit_metrics MultiJson.load(response.body)
        else
          log.error "ExMultiJson.load(response.body) expected 2xx from summary API, but got #{response.code}. Response body = #{response.body}"
        end
      rescue StandardError
        log.error "Failed to scrape metrics, error=#{$ERROR_INFO}"
        log.error_backtrace
      end
    end
  end
end

require 'aws-sdk-iam'
require 'aws-sdk-ec2'

module CapEC2
  class EC2Handler
    include CapEC2::Utils

    def initialize
      load_config
      configured_regions = get_regions(fetch(:ec2_region))
      @ec2 = {}
      configured_regions.each do |region|
        @ec2[region] = ec2_connect(region)
      end
    end

    def ec2_connect_by_role_arn(role_arn, region=nil)
      credentials = Aws::InstanceProfileCredentials.new(http_debug_output: $stdout)
      sts_client = Aws::STS::Client.new(region: region, credentials: credentials, http_wire_trace: false)
      temp_credentials = Aws::AssumeRoleCredentials.new(
        client: sts_client,
        role_arn: role_arn,
        role_session_name: "create-use-assume-role"
      )
      ec2_client = Aws::EC2::Client.new(credentials: temp_credentials, region: region)
    end

    def ec2_connect(region=nil)
      ec2_client = if fetch(:ec2_role_arn)
        ec2_connect_by_role_arn(fetch(:ec2_role_arn), region)
      else
        Aws::EC2::Client.new(
          access_key_id: fetch(:ec2_access_key_id),
          secret_access_key: fetch(:ec2_secret_access_key),
          region: region
        )
      end
      ec2_resource = Aws::EC2::Resource.new(client: ec2_client)
    end

    def status_table
      CapEC2::StatusTable.new(
        defined_roles.map {|r| get_servers_for_role(r)}.flatten.uniq {|i| i.instance_id}
      )
    end

    def server_names
      puts defined_roles.map {|r| get_servers_for_role(r)}
                   .flatten
                   .uniq {|i| i.instance_id}
                   .map {|i| tag_value(i, 'Name')}
                   .join("\n")
    end

    def instance_ids
      puts defined_roles.map {|r| get_servers_for_role(r)}
                   .flatten
                   .uniq {|i| i.instance_id}
                   .map {|i| i.instance_id}
                   .join("\n")
    end

    def defined_roles
      roles(:all).flat_map(&:roles_array).uniq.sort
    end

    def stage
      Capistrano::Configuration.env.fetch(:stage).to_s
    end

    def application
      Capistrano::Configuration.env.fetch(:application).to_s
    end

    def tag(tag_name)
      "tag:#{tag_name}"
    end

    def get_servers_for_role(role)
      filters = [
        {name: 'tag-key', values: [stages_tag, project_tag]},
        {name: tag(project_tag), values: ["*#{application}*"]},
        {name: 'instance-state-name', values: %w(running)}
      ]

      servers = []
      @ec2.each do |_, ec2|
        ec2_client = ec2.client
        ec2_client.describe_instances(filters: filters).reservations.each do |r|
          servers += r.instances.select do |i|
              instance_has_tag?(i, roles_tag, role) &&
                instance_has_tag?(i, stages_tag, stage) &&
                instance_has_tag?(i, project_tag, application) &&
                (fetch(:ec2_filter_by_status_ok?) ? instance_status_ok?(i) : true)
          end
        end
      end

      servers.sort_by { |s| tag_value(s, 'Name') || '' }
    end

    def get_server(instance_id)
      @ec2.reduce([]) do |acc, (_, ec2)|
        acc << ec2.instances[instance_id]
      end.flatten.first
    end

    private

    def instance_has_tag?(instance, key, value)
      # (tag_value(instance, key) || '').split(tag_delimiter).map(&:strip).include?(value.to_s)
      found_tag = instance.tags.find { |it| it.key == key.to_s }
      if found_tag
        found_tag.value.split(',').map(&:strip).include?(value.to_s)
      end
    end

    def instance_status_ok?(instance)
      @ec2.any? do |_, ec2|
        ec2.client.describe_instance_status(
          instance_ids: [instance.instance_id],
          filters: [{ name: 'instance-status.status', values: %w(ok) }]
        ).instance_statuses.length == 1
      end
    end
  end
end

require 'cloud/aws/stemcell_finder'
require 'uri'

module Bosh::AwsCloud
  class Cloud < Bosh::Cloud
    include Helpers

    METADATA_TIMEOUT = 5 # in seconds
    DEVICE_POLL_TIMEOUT = 60 # in seconds

    attr_reader :ec2_resource
    attr_reader :registry
    attr_accessor :logger

    ##
    # Initialize BOSH AWS CPI. The contents of sub-hashes are defined in the {file:README.md}
    # @param [Hash] options CPI options
    # @option options [Hash] aws AWS specific options
    # @option options [Hash] agent agent options
    # @option options [Hash] registry agent options
    def initialize(options)
      @config = Bosh::AwsCloud::Config.build(options.dup.freeze)

      @logger = Bosh::Clouds::Config.logger
      request_id = options['aws']['request_id']
      if request_id
        @logger.set_request_id(request_id)
      end

      @aws_provider = Bosh::AwsCloud::AwsProvider.new(@config.aws, @logger)
      @ec2_client = @aws_provider.ec2_client
      @ec2_resource = @aws_provider.ec2_resource

      cloud_error('Please make sure the CPI has proper network access to AWS.') unless @aws_provider.aws_accessible?

      @az_selector = AvailabilityZoneSelector.new(@ec2_resource)

      @registry = Bosh::Cpi::RegistryClient.new(
        @config.registry.endpoint,
        @config.registry.user,
        @config.registry.password
      )

      @instance_manager = InstanceManager.new(@ec2_resource, registry, @logger)
      @instance_type_mapper = InstanceTypeMapper.new

      @props_factory = Bosh::AwsCloud::PropsFactory.new(@config)

      @volume_manager = Bosh::AwsCloud::VolumeManager.new(@logger, @aws_provider)
      @disks_manager = Bosh::CPI::Disks.new(
        @logger,
        @volume_manager,
        @aws_provider,
        @az_selector,
        @config.aws,
        @registry
      )
    end

    ##
    # Reads current instance id from EC2 metadata. We are assuming
    # instance id cannot change while current process is running
    # and thus memoizing it.
    def current_vm_id
      begin
        return @current_vm_id if @current_vm_id

        http_client = HTTPClient.new
        http_client.connect_timeout = METADATA_TIMEOUT
        # Using 169.254.169.254 is an EC2 convention for getting
        # instance metadata
        uri = 'http://169.254.169.254/latest/meta-data/instance-id/'

        response = http_client.get(uri)
        unless response.status == 200
          cloud_error('Instance metadata endpoint returned ' \
                      "HTTP #{response.status}")
        end

        @current_vm_id = response.body
      rescue HTTPClient::TimeoutError
        cloud_error('Timed out reading instance metadata, ' \
                    'please make sure CPI is running on EC2 instance')
      end
    end

    ##
    # Create an EC2 instance and wait until it's in running state
    # @param [String] agent_id agent id associated with new VM
    # @param [String] stemcell_id AMI id of the stemcell used to
    #  create the new instance
    # @param [Hash] vm_type resource pool specification
    # @param [Hash] network_spec network specification, if it contains
    #  security groups they must already exist
    # @param [optional, Array] disk_locality list of disks that
    #   might be attached to this instance in the future, can be
    #   used as a placement hint (i.e. instance will only be created
    #   if resource pool availability zone is the same as disk
    #   availability zone)
    # @param [optional, Hash] environment data to be merged into
    #   agent settings
    # @return [String] EC2 instance id of the new virtual machine
    def create_vm(agent_id, stemcell_id, vm_type, network_spec, disk_locality = nil, environment = nil)
      with_thread_name("create_vm(#{agent_id}, ...)") do
        vm_props = @props_factory.vm_props(vm_type)
        network_props = @props_factory.network_props(network_spec)

        # do this early to fail fast
        target_groups = vm_props.lb_target_groups
        unless target_groups.empty?
          @aws_provider.alb_accessible?
        end

        requested_elbs = vm_props.elbs
        unless requested_elbs.empty?
          @aws_provider.elb_accessible?
        end

        stemcell = StemcellFinder.find_by_id(@ec2_resource, stemcell_id)

        begin
          instance, block_device_agent_info = @instance_manager.create(
            stemcell.image_id,
            vm_props,
            network_props,
            (disk_locality || []),
            @config.aws.default_security_groups
          )

          target_groups.each do |target_group_name|
            target_group = LBTargetGroup.new(client: @aws_provider.alb_client, group_name: target_group_name)
            target_group.register(instance.id)
          end

          requested_elbs.each do |requested_elb_name|
            requested_elb = ClassicLB.new(client: @aws_provider.elb_client, elb_name: requested_elb_name)
            requested_elb.register(instance.id)
          end

          logger.info("Creating new instance '#{instance.id}'")

          NetworkConfigurator.new(network_props).configure(@ec2_resource, instance)

          registry_settings = AgentSettings.new(
            agent_id,
            network_props,
            environment,
            stemcell.root_device_name,
            block_device_agent_info,
            @config.agent
          )
          registry.update_settings(instance.id, registry_settings.settings)

          instance.id
        rescue => e # is this rescuing too much?
          logger.error(%Q[Failed to create instance: #{e.message}\n#{e.backtrace.join("\n")}])
          instance.terminate(@config.aws.fast_path_delete?) if instance
          raise e
        end
      end
    end

    ##
    # Delete EC2 instance ("terminate" in AWS language) and wait until
    # it reports as terminated
    # @param [String] instance_id EC2 instance id
    def delete_vm(instance_id)
      with_thread_name("delete_vm(#{instance_id})") do
        logger.info("Deleting instance '#{instance_id}'")
        @instance_manager.find(instance_id).terminate(@config.aws.fast_path_delete?)
      end
    end

    ##
    # Reboot EC2 instance
    # @param [String] instance_id EC2 instance id
    def reboot_vm(instance_id)
      with_thread_name("reboot_vm(#{instance_id})") do
        @instance_manager.find(instance_id).reboot
      end
    end

    ##
    # Has EC2 instance
    # @param [String] instance_id EC2 instance id
    def has_vm?(instance_id)
      with_thread_name("has_vm?(#{instance_id})") do
        @instance_manager.find(instance_id).exists?
      end
    end

    ##
    # Creates a new EBS volume
    # @param [Integer] size disk size in MiB
    # @param [optional, String] instance_id EC2 instance id
    #        of the VM that this disk will be attached to
    # @return [String] created EBS volume id
    def create_disk(size, cloud_properties, instance_id = nil)
      with_thread_name("create_disk(#{size}, #{instance_id})") do
        raise ArgumentError, 'disk size needs to be an integer' unless size.kind_of?(Integer)
        props = @props_factory.disk_props(cloud_properties)
        vm_cid = Bosh::CPI::VMs.new_vm_cid(instance_id)

        @disks_manager.create_disk(size, props, vm_cid)
      end
    end

    ##
    # Check whether an EBS volume exists or not
    #
    # @param [String] disk_id EBS volume UUID
    # @return [bool] whether the specific disk is there or not
    def has_disk?(disk_id)
      with_thread_name("has_disk?(#{disk_id})") do
        disk_cid = Bosh::CPI::Disks.new_disk_cid(disk_id)

        @disks_manager.has_disk?(disk_cid)
      end
    end

    ##
    # Delete EBS volume
    # @param [String] disk_id EBS volume id
    # @raise [Bosh::Clouds::CloudError] if disk is not in available state
    def delete_disk(disk_id)
      with_thread_name("delete_disk(#{disk_id})") do
        disk_cid = Bosh::CPI::Disks.new_disk_cid(disk_id)

        @disks_manager.delete_disk(disk_cid)
      end
    end

    # Attach an EBS volume to an EC2 instance
    # @param [String] instance_id EC2 instance id of the virtual machine to attach the disk to
    # @param [String] disk_id EBS volume id of the disk to attach
    def attach_disk(instance_id, disk_id)
      with_thread_name("attach_disk(#{instance_id}, #{disk_id})") do
        vm_cid = Bosh::CPI::VMs.new_vm_cid(instance_id)
        disk_cid = Bosh::CPI::Disks.new_disk_cid(disk_id)

        @disks_manager.attach_disk(vm_cid, disk_cid)
      end

      # log registry settings for debugging
      logger.debug("updated registry settings: #{registry.read_settings(instance_id)}")
    end

    # Detach an EBS volume from an EC2 instance
    # @param [String] instance_id EC2 instance id of the virtual machine to detach the disk from
    # @param [String] disk_id EBS volume id of the disk to detach
    def detach_disk(instance_id, disk_id)
      with_thread_name("detach_disk(#{instance_id}, #{disk_id})") do
        vm_cid = Bosh::CPI::VMs.new_vm_cid(instance_id)
        disk_cid = Bosh::CPI::Disks.new_disk_cid(disk_id)

        @disks_manager.detach_disk(vm_cid, disk_cid)
      end
    end

    def get_disks(vm_id)
      vm_cid = VMs.new_vm_cid(vm_id)
      @disks_manager.get_disks(vm_cid)
    end

    # Take snapshot of disk
    # @param [String] disk_id disk id of the disk to take the snapshot of
    # @return [String] snapshot id
    def snapshot_disk(disk_id, metadata)
      metadata = Hash[metadata.map { |key, value| [key.to_s, value] }]

      with_thread_name("snapshot_disk(#{disk_id})") do
        volume = @ec2_resource.volume(disk_id)
        devices = []
        volume.attachments.each { |attachment| devices << attachment.device }

        name = ['deployment', 'job', 'index'].collect { |key| metadata[key] }
        name << devices.first.split('/').last unless devices.empty?

        snapshot = volume.create_snapshot(name.join('/'))
        logger.info("snapshot '#{snapshot.id}' of volume '#{disk_id}' created")


        tags = {}
        ['agent_id', 'instance_id', 'director_name', 'director_uuid'].each do |key|
          tags[key] = metadata[key]
        end
        tags['device'] = devices.first unless devices.empty?
        tags['Name'] = name.join('/')
        TagManager.tags(snapshot, tags)

        ResourceWait.for_snapshot(snapshot: snapshot, state: 'completed')
        snapshot.id
      end
    end

    # Delete a disk snapshot
    # @param [String] snapshot_id snapshot id to delete
    def delete_snapshot(snapshot_id)
      with_thread_name("delete_snapshot(#{snapshot_id})") do
        snapshot = @ec2_resource.snapshot(snapshot_id)
        begin
          snapshot.delete
        rescue Aws::EC2::Errors::InvalidSnapshotNotFound => e
          logger.info("snapshot '#{snapshot_id}' not found")
        end
        logger.info("snapshot '#{snapshot_id}' deleted")
      end
    end

    # Configure network for an EC2 instance. No longer supported.
    # @param [String] instance_id EC2 instance id
    # @param [Hash] network_spec network properties
    # @raise [Bosh::Clouds:NotSupported] configure_networks is no longer supported
    def configure_networks(instance_id, network_spec)
      raise Bosh::Clouds::NotSupported, 'configure_networks is no longer supported'
    end

    ##
    # Creates a new EC2 AMI using stemcell image.
    # This method can only be run on an EC2 instance, as image creation
    # involves creating and mounting new EBS volume as local block device.
    # @param [String] image_path local filesystem path to a stemcell image
    # @param [Hash] cloud_properties AWS-specific stemcell properties
    # @option cloud_properties [String] kernel_id
    #   AKI, auto-selected based on the architecture and root device, unless specified
    # @option cloud_properties [String] root_device_name
    #   block device path (e.g. /dev/sda1), provided by the stemcell manifest, unless specified
    # @option cloud_properties [String] architecture
    #   instruction set architecture (e.g. x86_64), provided by the stemcell manifest,
    #   unless specified
    # @option cloud_properties [String] disk (2048)
    #   root disk size
    # @return [String] EC2 AMI name of the stemcell
    def create_stemcell(image_path, stemcell_properties)
      with_thread_name("create_stemcell(#{image_path}...)") do
        props = @props_factory.stemcell_props(stemcell_properties)

        if props.is_light?
          # select the correct image for the configured ec2 client
          available_image = @ec2_resource.images(
            filters: [{
              name: 'image-id',
              values: props.ami_ids
            }]
          ).first
          raise Bosh::Clouds::CloudError, "Stemcell does not contain an AMI in region #{@config.aws.region}" unless available_image

          if props.encrypted
            copy_image_result = @ec2_client.copy_image(
              source_region: @config.aws.region,
              source_image_id: props.region_ami,
              name: "Copied from SourceAMI #{props.region_ami}",
              encrypted: props.encrypted,
              kms_key_id: props.kms_key_arn
            )

            encrypted_image_id = copy_image_result.image_id
            encrypted_image = @ec2_resource.image(encrypted_image_id)
            ResourceWait.for_image(image: encrypted_image, state: 'available')

            return "#{encrypted_image_id}"
          end

          "#{available_image.id} light"
        else
          create_ami_for_stemcell(image_path, props)
        end
      end
    end

    # Delete a stemcell and the accompanying snapshots
    # @param [String] stemcell_id EC2 AMI name of the stemcell to be deleted
    def delete_stemcell(stemcell_id)
      with_thread_name("delete_stemcell(#{stemcell_id})") do
        stemcell = StemcellFinder.find_by_id(@ec2_resource, stemcell_id)
        stemcell.delete
      end
    end

    # Add tags to an instance. In addition to the supplied tags,
    # it adds a 'Name' tag as it is shown in the AWS console.
    # @param [String] vm vm id that was once returned by {#create_vm}
    # @param [Hash] metadata metadata key/value pairs
    # @return [void]
    def set_vm_metadata(vm, metadata)
      metadata = Hash[metadata.map { |key, value| [key.to_s, value] }]

      instance = @ec2_resource.instance(vm)

      job = metadata['job']
      index = metadata['index']

      if metadata['name']
        metadata['Name'] = metadata.delete('name')
      elsif job && index
        metadata['Name'] = "#{job}/#{index}"
      elsif metadata['compiling']
        metadata['Name'] = "compiling/#{metadata['compiling']}"
      end

      TagManager.tags(instance, metadata)
    rescue Aws::EC2::Errors::TagLimitExceeded => e
      logger.error("could not tag #{instance.id}: #{e.message}")
    end

    def set_disk_metadata(disk_id, metadata)
      with_thread_name("set_disk_metadata(#{disk_id}, ...)") do
        disk_cid = Disks.new_disk_cid(disk_id)
        @disks_manager.set_disk_metadata(disk_cid, metadata)
      end
    end

    # Map a set of cloud agnostic VM properties (cpu, ram, ephemeral_disk_size) to
    # a set of AWS specific cloud_properties
    # @param [Hash] vm_properties requested cpu, ram, and ephemeral_disk_size
    # @return [Hash] AWS specific cloud_properties describing instance (e.g. instance_type)
    def calculate_vm_cloud_properties(vm_properties)
      required_keys = ['cpu', 'ram', 'ephemeral_disk_size']
      missing_keys = required_keys.reject { |key| vm_properties[key] }
      unless missing_keys.empty?
        missing_keys.map! { |k| "'#{k}'" }
        raise "Missing VM cloud properties: #{missing_keys.join(', ')}"
      end

      instance_type = @instance_type_mapper.map(vm_properties)
      {
        'instance_type' => instance_type,
        'ephemeral_disk' => {
          'size' => vm_properties['ephemeral_disk_size'],
        }
      }
    end

    # Information about AWS CPI, currently supported stemcell formats
    # @return [Hash] AWS CPI properties
    def info
      {'stemcell_formats' => ['aws-raw', 'aws-light']}
    end

    private

    attr_reader :az_selector

    def find_device_path_by_name(sd_name)
      xvd_name = sd_name.gsub(/^\/dev\/sd/, '/dev/xvd')

      DEVICE_POLL_TIMEOUT.times do
        if File.blockdev?(sd_name)
          return sd_name
        elsif File.blockdev?(xvd_name)
          return xvd_name
        end
        sleep(1)
      end

      cloud_error('Cannot find EBS volume on current instance')
    end

    def create_ami_for_stemcell(image_path, stemcell_cloud_props)
      creator = StemcellCreator.new(@ec2_resource, stemcell_cloud_props)

      begin
        director_vm_id = current_vm_id
        instance = nil
        volume = nil

        instance = @ec2_resource.instance(director_vm_id)
        unless instance.exists?
          cloud_error(
            "Could not locate the current VM with id '#{director_vm_id}'." +
                'Ensure that the current VM is located in the same region as configured in the manifest.'
          )
        end

        encrypted_disk_properties_hash = {}
        if stemcell_cloud_props.encrypted
          encrypted_disk_properties_hash['encrypted'] = stemcell_cloud_props.encrypted
          encrypted_disk_properties_hash['kms_key_arn'] = stemcell_cloud_props.kms_key_arn
        end

        volume_id = create_disk(
          stemcell_cloud_props.disk,
          encrypted_disk_properties_hash,
          director_vm_id
        )
        volume = @ec2_resource.volume(volume_id)

        sd_name = @volume_manager.attach_ebs_volume(instance, volume)
        device_path = find_device_path_by_name(sd_name)

        logger.info("Creating stemcell with: '#{volume.id}' and '#{stemcell_cloud_props.inspect}'")
        creator.create(volume, device_path, image_path).id
      rescue => e
        logger.error(e)
        raise e
      ensure
        if instance && volume
          @volume_manager.detach_ebs_volume(instance.reload, volume, true)
          @disks_manager.delete_disk(volume.id)
        end
      end
    end
  end
end

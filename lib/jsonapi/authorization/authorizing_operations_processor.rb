require 'pundit'

module JSONAPI
  module Authorization
    class AuthorizingOperationsProcessor < JSONAPI::Processor
      set_callback :find, :before, :authorize_find
      set_callback :show, :before, :authorize_show
      set_callback :show_relationship, :before, :authorize_show_relationship
      set_callback :show_related_resource, :before, :authorize_show_related_resource
      set_callback :show_related_resources, :before, :authorize_show_related_resources
      set_callback :create_resource, :before, :authorize_create_resource
      set_callback :remove_resource, :before, :authorize_remove_resource
      set_callback :replace_fields, :before, :authorize_replace_fields
      set_callback :replace_to_one_relationship, :before, :authorize_replace_to_one_relationship
      set_callback :create_to_many_relationship, :before, :authorize_create_to_many_relationship
      set_callback :replace_to_many_relationship, :before, :authorize_replace_to_many_relationship
      set_callback :remove_to_many_relationship, :before, :authorize_remove_to_many_relationship
      set_callback :remove_to_one_relationship, :before, :authorize_remove_to_one_relationship

      [
        :find,
        :show,
        :show_related_resource,
        :show_related_resources,
        :create_resource,
        :replace_fields
      ].each do |op_name|
        set_callback op_name, :after, :authorize_include_directive
      end

      def authorize_include_directive
        return if result.is_a?(::JSONAPI::ErrorsOperationResult)
        resources = Array.wrap(
          if result.respond_to?(:resources)
            result.resources
          elsif result.respond_to?(:resource)
            result.resource
          end
        )

        resources.each do |resource|
          authorize_model_includes(resource._model)
        end
      end

      def authorize_find
        authorizer.find(@resource_klass._model_class)
      end

      def authorize_show
        record = @resource_klass.find_by_key(
          operation_resource_id,
          context: context
        )._model

        authorizer.show(record)
      end

      def authorize_show_relationship
        parent_resource = @resource_klass.find_by_key(
          params[:parent_key],
          context: context
        )

        relationship = @resource_klass._relationship(params[:relationship_type].to_sym)

        related_resource =
          case relationship
          when JSONAPI::Relationship::ToOne
            parent_resource.public_send(params[:relationship_type].to_sym)
          when JSONAPI::Relationship::ToMany
            # Do nothing — already covered by policy scopes
          else
            raise "Unexpected relationship type: #{relationship.inspect}"
          end

        parent_record = parent_resource._model
        related_record = related_resource._model unless related_resource.nil?
        authorizer.show_relationship(parent_record, related_record)
      end

      def authorize_show_related_resource
        source_klass = params[:source_klass]
        source_id = params[:source_id]
        relationship_type = params[:relationship_type].to_sym

        source_resource = source_klass.find_by_key(source_id, context: context)

        related_resource = source_resource.public_send(relationship_type)

        source_record = source_resource._model
        related_record = related_resource._model unless related_resource.nil?
        authorizer.show_related_resource(source_record, related_record)
      end

      def authorize_show_related_resources
        source_record = params[:source_klass].find_by_key(
          params[:source_id],
          context: context
        )._model

        authorizer.show_related_resources(source_record)
      end

      def authorize_replace_fields
        source_record = @resource_klass.find_by_key(
          params[:resource_id],
          context: context
        )._model

        authorizer.replace_fields(source_record, related_models)
      end

      def authorize_create_resource
        source_class = @resource_klass._model_class

        authorizer.create_resource(source_class, related_models)
      end

      def authorize_remove_resource
        record = @resource_klass.find_by_key(
          operation_resource_id,
          context: context
        )._model

        authorizer.remove_resource(record)
      end

      def authorize_replace_to_one_relationship
        source_resource = @resource_klass.find_by_key(
          params[:resource_id],
          context: context
        )
        source_record = source_resource._model

        old_related_record = source_resource.records_for(params[:relationship_type].to_sym)
        unless params[:key_value].nil?
          new_related_resource = @resource_klass._relationship(params[:relationship_type].to_sym).resource_klass.find_by_key(
            params[:key_value],
            context: context
          )
          new_related_record = new_related_resource._model unless new_related_resource.nil?
        end

        authorizer.replace_to_one_relationship(
          source_record,
          old_related_record,
          new_related_record
        )
      end

      def authorize_create_to_many_relationship
        source_record = @resource_klass.find_by_key(
          params[:resource_id],
          context: context
        )._model

        related_models =
          model_class_for_relationship(params[:relationship_type].to_sym).find(params[:data])

        authorizer.create_to_many_relationship(source_record, related_models)
      end

      def authorize_replace_to_many_relationship
        source_resource = @resource_klass.find_by_key(
          params[:resource_id],
          context: context
        )
        source_record = source_resource._model

        related_records = source_resource.records_for(params[:relationship_type].to_sym)

        authorizer.replace_to_many_relationship(
          source_record,
          related_records
        )
      end

      def authorize_remove_to_many_relationship
        source_resource = @resource_klass.find_by_key(
          params[:resource_id],
          context: context
        )
        source_record = source_resource._model

        related_resource = @resource_klass._relationship(params[:relationship_type].to_sym).resource_klass.find_by_key(
          params[:associated_key],
          context: context
        )
        related_record = related_resource._model unless related_resource.nil?

        authorizer.remove_to_many_relationship(
          source_record,
          related_record
        )
      end

      def authorize_remove_to_one_relationship
        source_resource = @resource_klass.find_by_key(
          params[:resource_id],
          context: context
        )

        related_resource = source_resource.public_send(params[:relationship_type].to_sym)

        source_record = source_resource._model
        related_record = related_resource._model unless related_resource.nil?
        authorizer.remove_to_one_relationship(source_record, related_record)
      end

      private

      def authorizer
        @authorizer ||= ::JSONAPI::Authorization.configuration.authorizer.new(context)
      end

      # TODO: Communicate with upstream to fix this nasty hack
      def operation_resource_id
        case operation_type
        when :show
          params[:id]
        when :show_related_resources
          params[:source_id]
        else
          params[:resource_id]
        end
      end

      def resource_class_for_relationship(assoc_name)
        @resource_klass._relationship(assoc_name).resource_klass
      end

      def model_class_for_relationship(assoc_name)
        resource_class_for_relationship(assoc_name)._model_class
      end

      def related_models
        data = params[:data]
        return [] if data.nil?

        [:to_one, :to_many].flat_map do |rel_type|
          data[rel_type].flat_map do |assoc_name, assoc_value|
            case assoc_value
            when Hash # polymorphic relationship
              resource_class = @resource_klass.resource_for(assoc_value[:type].to_s)
              resource_class.find_by_key(assoc_value[:id], context: context)._model
            else
              resource_class = resource_class_for_relationship(assoc_name)
              primary_key = resource_class._primary_key
              resource_class._model_class.where(primary_key => assoc_value)
            end
          end
        end
      end

      def authorize_model_includes(source_record)
        if params[:include_directives]
          params[:include_directives].model_includes.each do |include_item|
            authorize_include_item(@resource_klass, source_record, include_item)
          end
        end
      end

      def authorize_include_item(resource_klass, source_record, include_item)
        case include_item
        when Hash
          # e.g. {articles: [:comments, :author]} when ?include=articles.comments,articles.author
          include_item.each do |rel_name, deep|
            authorize_include_item(resource_klass, source_record, rel_name)
            relationship = resource_klass._relationship(rel_name)
            next_resource_klass = relationship.resource_klass
            Array.wrap(
              source_record.public_send(
                relationship.relation_name(context)
              )
            ).each do |next_source_record|
              deep.each do |next_include_item|
                authorize_include_item(
                  next_resource_klass,
                  next_source_record,
                  next_include_item
                )
              end
            end
          end
        when Symbol
          relationship = resource_klass._relationship(include_item)
          case relationship
          when JSONAPI::Relationship::ToOne
            related_record = source_record.public_send(
              relationship.relation_name(context)
            )
            return if related_record.nil?
            authorizer.include_has_one_resource(source_record, related_record)
          when JSONAPI::Relationship::ToMany
            authorizer.include_has_many_resource(
              source_record,
              relationship.resource_klass._model_class
            )
          else
            raise "Unexpected relationship type: #{relationship.inspect}"
          end
        else
          raise "Unknown include directive: #{include_item}"
        end
      end
    end
  end
end

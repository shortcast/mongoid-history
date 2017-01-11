module Mongoid
  module History
    module Tracker
      extend ActiveSupport::Concern

      included do
        include Mongoid::Document
        include Mongoid::Timestamps
        attr_writer :trackable

        field :association_chain,       type: Array, default: []
        field :modified,                type: Hash, default: {}
        field :original,                type: Hash, default: {}
        field :version,                 type: Integer
        field :action,                  type: String
        field :scope,                   type: String
        belongs_to :modifier, class_name: Mongoid::History.modifier_class_name, required: false

        index(scope: 1)
        index(association_chain: 1)

        Mongoid::History.tracker_class_name = name.tableize.singularize.to_sym
      end

      def undo!(modifier = nil)
        if action.to_sym == :destroy
          re_create
        elsif action.to_sym == :create
          re_destroy
        elsif Mongoid::Compatibility::Version.mongoid3?
          trackable.update_attributes!(undo_attr(modifier), without_protection: true)
        else
          trackable.update_attributes!(undo_attr(modifier))
        end
      end

      def redo!(modifier = nil)
        if action.to_sym == :destroy
          re_destroy
        elsif action.to_sym == :create
          re_create
        elsif Mongoid::Compatibility::Version.mongoid3?
          trackable.update_attributes!(redo_attr(modifier), without_protection: true)
        else
          trackable.update_attributes!(redo_attr(modifier))
        end
      end

      def undo_attr(modifier)
        undo_hash = affected.easy_unmerge(modified)
        undo_hash.easy_merge!(original)
        modifier_field = trackable.history_trackable_options[:modifier_field]
        undo_hash[modifier_field] = modifier
        (modified.keys - undo_hash.keys).each do |k|
          undo_hash[k] = nil
        end
        localize_keys(undo_hash)
      end

      def redo_attr(modifier)
        redo_hash = affected.easy_unmerge(original)
        redo_hash.easy_merge!(modified)
        modifier_field = trackable.history_trackable_options[:modifier_field]
        redo_hash[modifier_field] = modifier
        localize_keys(redo_hash)
      end

      def trackable_root
        @trackable_root ||= trackable_parents_and_trackable.first
      end

      def trackable
        @trackable ||= trackable_parents_and_trackable.last
      end

      def trackable_parents
        @trackable_parents ||= trackable_parents_and_trackable[0, -1]
      end

      def trackable_parent
        @trackable_parent ||= trackable_parents_and_trackable[-2]
      end

      # Outputs a :from, :to hash for each affected field. Intentionally excludes fields
      # which are not tracked, even if there are tracked values for such fields
      # present in the database.
      #
      # @return [ HashWithIndifferentAccess ] a change set in the format:
      #   { field_1: {to: new_val}, field_2: {from: old_val, to: new_val} }
      def tracked_changes
        @tracked_changes ||= (modified.keys | original.keys).inject(HashWithIndifferentAccess.new) do |h, k|
          h[k] = { from: original[k], to: modified[k] }.delete_if { |_, vv| vv.nil? }
          h
        end.delete_if { |k, v| v.blank? || !trackable_parent_class.tracked?(k) }
      end

      # Outputs summary of edit actions performed: :add, :modify, :remove, or :array.
      # Does deep comparison of arrays. Useful for creating human-readable representations
      # of the history tracker. Considers changing a value to 'blank' to be a removal.
      #
      # @return [ HashWithIndifferentAccess ] a change set in the format:
      #   { add: { field_1: new_val, ... },
      #     modify: { field_2: {from: old_val, to: new_val}, ... },
      #     remove: { field_3: old_val },
      #     array: { field_4: {add: ['foo', 'bar'], remove: ['baz']} } }
      def tracked_edits
        return @tracked_edits if @tracked_edits
        @tracked_edits = HashWithIndifferentAccess.new

        tracked_changes.each do |k, v|
          next if v[:from].blank? && v[:to].blank?

          if trackable_parent_class.tracked_embeds_many?(k)
            prepare_tracked_edits_for_embeds_many(k, v)
          elsif v[:from].blank?
            @tracked_edits[:add] ||= {}
            @tracked_edits[:add][k] = v[:to]
          elsif v[:to].blank?
            @tracked_edits[:remove] ||= {}
            @tracked_edits[:remove][k] = v[:from]
          elsif v[:from].is_a?(Array) && v[:to].is_a?(Array)
            @tracked_edits[:array] ||= {}
            old_values = v[:from] - v[:to]
            new_values = v[:to] - v[:from]
            @tracked_edits[:array][k] = { add: new_values, remove: old_values }.delete_if { |_, vv| vv.blank? }
          else
            @tracked_edits[:modify] ||= {}
            @tracked_edits[:modify][k] = v
          end
        end
        @tracked_edits
      end

      # Similar to #tracked_changes, but contains only a single value for each
      # affected field:
      #   - :create and :update return the modified values
      #   - :destroy returns original values
      # Included for legacy compatibility.
      #
      # @deprecated
      #
      # @return [ HashWithIndifferentAccess ] a change set in the format:
      #   { field_1: value, field_2: value }
      def affected
        target = action.to_sym == :destroy ? :from : :to
        @affected ||= tracked_changes.inject(HashWithIndifferentAccess.new) do |h, (k, v)|
          h[k] = v[target]
          h
        end
      end

      # Returns the class of the trackable, irrespective of whether the trackable object
      # has been destroyed.
      #
      # @return [ Class ] the class of the trackable
      def trackable_parent_class
        association_chain.first['name'].constantize
      end

      private

      def re_create
        association_chain.length > 1 ? create_on_parent : create_standalone
      end

      def re_destroy
        trackable.destroy
      end

      def create_standalone
        restored = trackable_parent_class.new(localize_keys(original))
        restored.id = original['_id']
        restored.save!
      end

      def create_on_parent
        name = association_chain.last['name']
        if trackable_parent.class.embeds_one?(name)
          trackable_parent.create_embedded(name, localize_keys(original))
        elsif trackable_parent.class.embeds_many?(name)
          trackable_parent.get_embedded(name).create!(localize_keys(original))
        else
          fail 'This should never happen. Please report bug!'
        end
      end

      def trackable_parents_and_trackable
        @trackable_parents_and_trackable ||= traverse_association_chain
      end

      def traverse_association_chain
        chain = association_chain.dup
        doc = nil
        documents = []
        loop do
          node = chain.shift
          name = node['name']
          doc = if doc.nil?
                  # root association. First element of the association chain
                  # unscoped is added to remove any default_scope defined in model
                  klass = name.classify.constantize
                  klass.unscoped.where(_id: node['id']).first
                elsif doc.class.embeds_one?(name)
                  doc.get_embedded(name)
                elsif doc.class.embeds_many?(name)
                  doc.get_embedded(name).unscoped.where(_id: node['id']).first
                else
                  fail 'This should never happen. Please report bug.'
                end
          documents << doc
          break if chain.empty?
        end
        documents
      end

      def localize_keys(hash)
        klass = association_chain.first['name'].constantize
        klass.localized_fields.keys.each do |name|
          hash["#{name}_translations"] = hash.delete(name) if hash[name].present?
        end if klass.respond_to?(:localized_fields)
        hash
      end

      def prepare_tracked_edits_for_embeds_many(key, value)
        @tracked_edits[:embeds_many] ||= {}
        value[:from] ||= []
        value[:to] ||= []
        modify_ids = value[:from].map { |vv| vv['_id'] }.compact & value[:to].map { |vv| vv['_id'] }.compact
        modify_values = modify_ids.map { |id| { from: value[:from].detect { |vv| vv['_id'] == id }, to: value[:to].detect { |vv| vv['_id'] == id } } }
        modify_values.delete_if { |vv| vv[:from] == vv[:to] }
        ignore_values = modify_values.map { |vv| [vv[:from], vv[:to]] }.flatten
        old_values = value[:from] - value[:to] - ignore_values
        new_values = value[:to] - value[:from] - ignore_values
        @tracked_edits[:embeds_many][key] = { add: new_values, remove: old_values, modify: modify_values }.delete_if { |_, vv| vv.blank? }
      end
    end
  end
end

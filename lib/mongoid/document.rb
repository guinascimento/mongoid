# encoding: utf-8
module Mongoid #:nodoc:
  module Document
    def self.included(base)
      base.class_eval do
        include Components
        include InstanceMethods
        extend ClassMethods

        cattr_accessor :_collection, :collection_name, :embedded, :primary_key

        self.embedded = false
        self.collection_name = self.name.collectionize

        attr_accessor :association_name, :_parent
        attr_reader :attributes, :new_record

        delegate :collection, :embedded, :primary_key, :to => "self.class"
      end
    end

    module ClassMethods
      # Returns the collection associated with this +Document+. If the
      # document is embedded, there will be no collection associated
      # with it.
      #
      # Returns: <tt>Mongo::Collection</tt>
      def collection
        raise Errors::InvalidCollection.new(self) if embedded
        self._collection ||= Mongoid.database.collection(self.collection_name)
        add_indexes; self._collection
      end

      # Returns a human readable version of the class.
      #
      # Example:
      #
      # <tt>MixedDrink.human_name # returns "Mixed Drink"</tt>
      def human_name
        name.labelize
      end

      # Instantiate a new object, only when loaded from the database or when
      # the attributes have already been typecast.
      #
      # Example:
      #
      # <tt>Person.instantiate(:title => "Sir", :age => 30)</tt>
      def instantiate(attrs = {}, allocating = false)
        attributes = attrs.with_indifferent_access
        if attributes[:_id] || allocating
          document = allocate
          document.instance_variable_set(:@attributes, attributes)
          return document
        else
          return new(attributes)
        end
      end

      # Defines the field that will be used for the id of this +Document+. This
      # set the id of this +Document+ before save to a parameterized version of
      # the field that was supplied. This is good for use for readable URLS in
      # web applications.
      #
      # Example:
      #
      #   class Person
      #     include Mongoid::Document
      #     field :first_name
      #     field :last_name
      #     key :first_name, :last_name
      #   end
      def key(*fields)
        self.primary_key = fields
        before_save :generate_key
      end

      # Macro for setting the collection name to store in.
      #
      # Example:
      #
      # <tt>Person.store_in :populdation</tt>
      def store_in(name)
        self.collection_name = name.to_s
        self._collection = Mongoid.database.collection(name.to_s)
      end

      # Returns all types to query for when using this class as the base.
      def _types
        @_type ||= (self.subclasses + [ self.name ])
      end

    end

    module InstanceMethods
      # Performs equality checking on the attributes. For now we chack against
      # all attributes excluding timestamps on the object.
      def ==(other)
        return false unless other.is_a?(Document)
        @attributes.except(:modified_at).except(:created_at) ==
          other.attributes.except(:modified_at).except(:created_at)
      end

      # Introduces a child object into the +Document+ object graph. This will
      # set up the relationships between the parent and child and update the
      # attributes of the parent +Document+.
      #
      # Options:
      #
      # parent: The +Document+ to assimilate with.
      # options: The association +Options+ for the child.
      #
      # Example:
      #
      # <tt>name.assimilate(person, options)</tt>
      #
      # Returns: The child +Document+.
      def assimilate(parent, options)
        parentize(parent, options.name); notify; self
      end

      # Clone the current +Document+. This will return all attributes with the
      # exception of the document's id and versions.
      def clone
        self.class.instantiate(@attributes.except(:_id).except(:versions).dup, true)
      end

      # Instantiate a new +Document+, setting the Document's attributes if
      # given. If no attributes are provided, they will be initialized with
      # an empty +Hash+.
      #
      # If a primary key is defined, the document's id will be set to that key,
      # otherwise it will be set to a fresh +Mongo::ObjectID+ string.
      #
      # Options:
      #
      # attrs: The attributes +Hash+ to set up the document with.
      #
      # Example:
      #
      # <tt>Person.new(:title => "Mr", :age => 30)</tt>
      def initialize(attrs = {})
        @attributes = {}.with_indifferent_access
        process(defaults.merge(attrs))
        @new_record = true if id.nil?
        document = yield self if block_given?
        generate_key; generate_type; document
      end

      # Returns the class name plus its attributes.
      def inspect
        attrs = fields.map { |name, field| "#{name}: #{@attributes[name] || 'nil'}" } * ", "
        "#<#{self.class.name} _id: #{id}, #{attrs}>"
      end

      # Returns true is the +Document+ has not been persisted to the database,
      # false if it has. This is determined by the variable @new_record
      # and NOT if the object has an id.
      def new_record?
        @new_record == true
      end

      # Sets the new_record boolean - used after document is saved.
      def new_record=(saved)
        @new_record = saved
      end

      # Set the changed state of the +Document+ then notify observers that it has changed.
      #
      # Example:
      #
      # <tt>person.notify</tt>
      def notify
        changed(true)
        notify_observers(self)
      end

      # Sets up a child/parent association. This is used for newly created
      # objects so they can be properly added to the graph and have the parent
      # observers set up properly.
      #
      # Options:
      #
      # abject: The parent object that needs to be set for the child.
      # association_name: The name of the association for the child.
      #
      # Example:
      #
      # <tt>address.parentize(person, :addresses)</tt>
      def parentize(object, association_name)
        self._parent = object
        self.association_name = association_name
        add_observer(object)
      end

      # Reloads the +Document+ attributes from the database.
      def reload
        @attributes = collection.find_one(:_id => id).with_indifferent_access
      end

      # Remove a child document from this parent +Document+. Will reset the
      # memoized association and notify the parent of the change.
      def remove(child)
        name = child.association_name
        reset(name) { @attributes.remove(name, child.attributes) }
        notify
      end

      # Return the root +Document+ in the object graph. If the current +Document+
      # is the root object in the graph it will return self.
      def _root
        object = self
        while (object._parent) do object = object._parent; end
        object || self
      end

      # Return an array with this +Document+ only in it.
      def to_a
        [ self ]
      end

      # Return this document as a JSON string. Nothing special is required here
      # since Mongoid bubbles up all the child associations to the parent
      # attribute +Hash+ using observers throughout the +Document+ lifecycle.
      #
      # Example:
      #
      # <tt>person.to_json</tt>
      def to_json
        @attributes.to_json
      end

      # Returns the id of the Document, used in Rails compatibility.
      def to_param
        id
      end

      # Observe a notify call from a child +Document+. This will either update
      # existing attributes on the +Document+ or clear them out for the child if
      # the clear boolean is provided.
      #
      # Options:
      #
      # child: The child +Document+ that sent the notification.
      # clear: Will clear out the child's attributes if set to true.
      #
      # Example:
      #
      # <tt>person.notify_observers(self)</tt> will cause this method to execute.
      #
      # This will also cause the observing +Document+ to notify it's parent if
      # there is any.
      def update(child, clear = false)
        name = child.association_name
        clear ? @attributes.delete(name) : @attributes.insert(name, child.attributes)
        notify
      end

      protected
      def generate_key
        if primary_key
          @attributes[:_id] = extract_keys.join(" ").identify
        else
          @attributes[:_id] = Mongo::ObjectID.new.to_s unless id
        end
      end

      def generate_type
        @attributes[:_type] ||= self.class.name
      end

      def extract_keys
        primary_key.collect { |key| @attributes[key] }.reject { |val| val.nil? }
      end

    end

  end

end

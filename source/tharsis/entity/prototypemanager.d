//          Copyright Ferdinand Majerech 2013-2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module tharsis.entity.prototypemanager;

import std.algorithm;
import std.exception;
import std.typecons;

import tharsis.entity.componenttypeinfo;
import tharsis.entity.componenttypemanager;
import tharsis.entity.entitymanager;
import tharsis.entity.entityprototype;
import tharsis.entity.resourcemanager;
import tharsis.util.interfaces;
import tharsis.util.qualifierhacks;


// TODO: Add a method to specify resources to preload at start instead of always
//       loading on demand. Try to find a generic way to do this for all or most
//       (e.g. only with StringDescriptors-files) resources/resourcemanagers.

/** Base class for resource managers managing entity prototypes.
 *
 * A project may need multiple entity prototype resource types; these should be managed
 * by separate resource managers derived from BasePrototypeManager templated with the
 * resource type.
 *
 * The Resource type should define following members in addition to the Descriptor type
 * required by ResourceManager:
 *
 * -------------------------------
 * // Constructor from descriptor.
 * this(ref Descriptor);
 * // The prototype stored by the resource (once loaded)
 * EntityPrototype prototype;
 * // Descriptor describing this resource.
 * Descriptor descriptor;
 * // The current resource state.
 * ResourceState state;
 * -------------------------------
 *
 * For an example Resource type, see
 * tharsis.entity.entityprototype.EntityPrototypeResource .
 */
class BasePrototypeManager(Resource) : MallocResourceManager!Resource
{
private:
    // Memory used by loaded (immutable) prototypes in resources_ to store components.
    PartiallyMutablePagedBuffer prototypeData_;

public:
    /** BasePrototypeManager constructor.
     *
     * Params:
     *
     * Source               = Type of source to load prototypes from (e.g. YAMLSource).
     * Policy               = Policy used with the entity manager, specifying
     *                        compile-time tweakables.
     * componentTypeManager = Component type manager where all used component types are
     *                        registered.
     * entityManager        = The entity manager.
     * getPrototypeSource   = A deleg that takes a resource descriptor (which has the
     *                        Descriptor type as defined by the Resource type parameter
     *                        of BasePrototypeManager) and returns a Source storing an
     *                        entity prototype.
     *                        Returned source may be null (Source.isNull == true) if the
     *                        source could not be loaded.
     */
    this(Source, Policy)(ComponentTypeManager!(Source, Policy) componentTypeManager,
                         EntityManager!Policy entityManager,
                         Source delegate(ref Descriptor) nothrow getPrototypeSource)
        @trusted nothrow
    {
        /** Load a component of type componentType from componentSource to prototype.
         *
         * Params:
         *
         * componentType   = Type of the component to load.
         * componentSource = Source to load the component from.
         * prototype       = Prototype to load the component into. Must not be locked yet.
         * errorLog        = A string to write any loading errors to. If there are no
         *                   errors, this is not touched.
         *
         * Returns: true if the component was successfully loaded, false otherwise.
         */
        bool loadComponent(ref const(ComponentTypeInfo) componentType,
                           ref Source componentSource, ref EntityPrototype prototype,
                           ref string errorLog) nothrow
        {
            ubyte[] storage = prototype.allocateComponent(componentType);
            if(!componentType.loadComponent(storage, componentSource, entityManager, errorLog))
            {
                // Failed to load the component.
                return false;
            }
            return true;
        }

        /** Load multicomponents of type componentType from sequence to prototype.
         *
         * Params:
         *
         * componentType = Type of components to load. Must be a MultiComponent type.
         * sequence      = Source storing a sequence of components.
         * prototype     = Prototype to load the components into. Must not be locked yet.
         * errorLog      = A string to write any loading errors to. If there are no
         *                 errors, this is not touched.
         *
         * Returns: true if all components successfully loaded, false if either a) there
         *          are zero components (empty sequence), b) a component could not be
         *          loaded, or c) there are more components than the max number of
         *          components of type componentType per entity (this limit is specified
         *          in the component struct).
         */
        bool loadMultiComponent(ref const(ComponentTypeInfo) componentType,
                                ref Source sequence, ref EntityPrototype prototype,
                                ref string errorLog) nothrow
        {
            size_t count = 0;
            Source componentSource;
            if(sequence.isSequence) while(sequence.getSequenceValue(count, componentSource))
            {
                if(!loadComponent(componentType, componentSource, prototype, errorLog))
                {
                    return false;
                }
                ++count;
                if(count > componentType.maxPerEntity)
                {
                    // Too many components of this type.
                    return false;
                }
            }

            // Zero components of this type (or a non-sequence Source): loading failed.
            return count == 0 ? false : true;
        }

        /** Load an entity prototype resource.
         *
         * Params:
         *
         * resource = Resource to load. State of the resource will be set to Loaded if
         *            loaded successfully, LoadFailed otherwise.
         * errorLog = A string to write any loading errors to. If there are no errors,
         *            this is not touched.
         */
        void loadResource(ref Resource resource, ref string errorLog) @trusted nothrow
        {
            auto typeMgr = componentTypeManager;
            // Get the source (e.g. YAML) storing the prototype. May fail e.g if
            // getPrototypeSource looks for the source in a nonexistent file.
            Source source = getPrototypeSource(resource.descriptor);
            if(source.isNull)
            {
                resource.state = ResourceState.LoadFailed;
                return;
            }
            // A shortcut pointer for less typing.
            EntityPrototype* prototype = &resource.prototype;
            // Provide memory to the prototype.
            ubyte[] storage = prototypeData_.getBytes(prototype.maxPrototypeBytes(typeMgr));
            prototype.useMemory(storage);

            const ComponentTypeInfo[] typeInfo = typeMgr.componentTypeInfo[];
            scope(exit)
            {
                assert([ResourceState.Loaded, ResourceState.LoadFailed].canFind(resource.state),
                       "Unexpected prototype resource state after loading");

                const loaded = resource.state == ResourceState.Loaded;
                // The prototype should return any memory it does not use.
                prototypeData_.lockBytes(loaded ? prototype.lockAndTrimMemory(typeInfo)
                                                : storage[0 .. 0]);
            }

            if(!source.isMapping)
            {
                resource.state = ResourceState.LoadFailed;
                return;
            }
            // Load components of the entity. Look for components of all types.
            foreach(ref type; typeInfo) if(!type.isNull)
            {
                Source compSrc;
                // No component of this type in the source.
                if(!source.getMappingValue(type.sourceName, compSrc))
                {
                    continue;
                }

                if(type.isMulti ? !loadMultiComponent(type, compSrc, *prototype, errorLog)
                                : !loadComponent(type, compSrc, *prototype, errorLog))
                {
                    resource.state = ResourceState.LoadFailed;
                    return;
                }
            }

            resource.state = ResourceState.Loaded;
        }

        super(&loadResource);
    }

    /// Deallocate all resource arrays.
    override void clear() @trusted
    {
        super.clear();
        destroy(prototypeData_);
    }
}

/// Manages entity prototypes defined in files or inline in a Source.
class PrototypeManager: BasePrototypeManager!EntityPrototypeResource
{
public:
    /** Construct a PrototypeManager.
     *
     * Params: Source               = Type of source to load prototypes from (e.g.
     *                                YAMLSource)
     *         Policy               = Policy used with the entity manager, specifying
     *                                compile-time tweakables.
     *         componentTypeManager = Component type manager where all used component
     *                                types are registered.
     *         entityManager        = The entity manager.
     */
    this(Source, Policy)
        (ComponentTypeManager!(Source, Policy) componentTypeManager,
         EntityManager!Policy entityManager) @safe nothrow
    {
        // An EntityPrototypeResource descriptor contains the file name where the
        // prototype is defined. The prototype manager gets the prototype source by
        // loading source from that file.
        super(componentTypeManager, entityManager,
              (ref Descriptor d) => d.source!Source(componentTypeManager.sourceLoader));
    }
}
unittest
{
    import tharsis.util.pagedarray;
    PagedArray!EntityPrototypeResource testPrototypes;
}

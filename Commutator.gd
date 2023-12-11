tool
class_name Com
"""
	This is a refless communication library.
"""

const DEF_PRIORITY = 10
const FUNC_PATTERN : = "COM{priority}_{func_name}"

const _METHODS : = {
	#  func_name : [ [object1, method, priority], [object2, method, priority] ] 
}
const _FIRSTS_METHODS : = { # optimization
	#  func_name : [object1, method, priority]
}
# TODO: propagate_register and childs_invoke (also can make separate commutator object)


static func has(method :String) -> bool:
	if _FIRSTS_METHODS.has(method) and FRef.is_valid(_FIRSTS_METHODS[method]):
		return true
	var func_list = _METHODS.get(method)
	return (func_list is Array) and (FRef.get_first_valid(func_list) != null)


static func invoke(method :String, args :Array = [], def_result = null, caller :Object = null): # -> Variant
	var result = _call_first(method, args)
	return result if result != null else def_result

# Always return coroutine, this function used for yield:
static func await(method :String, args :Array = [], caller :Object = null) -> GDScriptFunctionState:
	var result = invoke(method, args, caller)
	if result is GDScriptFunctionState:
		result = yield(result, "completed")
	else:
		yield(Engine.get_main_loop(), "idle_frame")
	return result


static func query(method :String, args :Array = [], caller :Object = null) -> Dictionary:
	var results : = {}
	var func_list = _METHODS.get(method)
	if func_list is Array:
		FRef.fix_list(func_list)
		for fref in func_list:
			var result = FRef.call_func(fref, args)
			if result is GDScriptFunctionState:
				result = yield(result, "completed")
			var obj = FRef.get_obj(fref)
			results[obj] = result
	return results


static func dispatch(topic :String, args :Array = [], sender :Object = null) -> void:
	_call_first_deferred(topic, args)


static func notify(topic :String, args :Array = [], sender :Object = null) -> void:
	var func_list = _METHODS.get(topic)
	if func_list is Array:
		FRef.fix_list(func_list)
		for fref in func_list:
			FRef.call_func(fref, args)


static func notify_deferred(topic :String, args :Array = [], sender :Object = null) -> void:
	yield(Engine.get_main_loop(), "idle_frame")
	notify(topic, args, sender)


static func register(obj :Object) -> void:
	if not is_instance_valid(obj):
		return
	FRef.set_autosort(false)
	var methods : = Parser.parse_object_methods(obj)
	for method_name in methods:
		publish_method(obj, method_name, methods[method_name])
	for topic in _METHODS:
		var fref_list = _METHODS[topic]
		FRef.sort_list(fref_list)
		_FIRSTS_METHODS[topic] = FRef.get_first_valid(fref_list)
	FRef.set_autosort(true)


static func unregister(obj :Object) -> void:
	if not is_instance_valid(obj):
		return
	for topic in _METHODS:
		var fref_list = _METHODS[topic]
		for fref in fref_list:
			if FRef.get_obj(fref) == obj:
				fref[0] = null
		FRef.fix_list(fref_list)
		_FIRSTS_METHODS[topic] = FRef.get_first_valid(fref_list)


static func publish_method(obj :Object, method :String, params = null) -> void:
	if not is_instance_valid(obj) or method.empty():
		return
	if params == null:
		params = {func_name = method, priority = DEF_PRIORITY}
	if not params.has_all(["func_name", "priority"]):
		Parser.parse_method(method, params)
	if params.get("func_name","").empty():
		return
	var fref_list = _METHODS.get(params.func_name, [])
	FRef.add_to_list(fref_list, obj, method, params.priority)
	_METHODS[params.func_name] = fref_list
	_FIRSTS_METHODS[params.func_name] = FRef.get_first_valid(fref_list)


static func unpublish_method(obj :Object, method :String, func_name :String = "") -> void:
	if not is_instance_valid(obj):
		return
	if func_name.empty():
		var params : = {}
		Parser.parse_method(method, params)
		func_name = params.func_name
	if func_name in _METHODS:
		var fref_list :Array = _METHODS[func_name]
		FRef.remove_from_list(fref_list, obj, method)
		_FIRSTS_METHODS[func_name] = FRef.get_first_valid(fref_list)


static func _call_first(method :String, args :Array = []): # -> Variant
	var fref = _get_first_fref(method)
	if fref:
		return FRef.call_func(fref, args)


static func _call_first_deferred(method :String, args :Array = []): # -> Variant
	var fref = _get_first_fref(method)
	if fref:
		FRef.call_func_deferred(fref, args)


static func _get_first_fref(method :String):
	var fref = _FIRSTS_METHODS.get(method)
	if (fref is Array) and FRef.is_valid(fref):
		return fref
	var func_list = _METHODS.get(method)
	if (func_list is Array) and (not func_list.empty()):
		fref = FRef.get_first_valid(func_list)
	if fref and FRef.is_valid(fref):
		_FIRSTS_METHODS[method] = fref
		return fref
	return null



class Parser:
	const _CACHES : = {
		methods = {},   # { method_name : params }
		classes = {},  # { Script : { method_name : params } }
		class_checksums = {},
	}
	
	static func parse_object_methods(obj :Object) -> Dictionary:
		var method_list : = obj.get_method_list()
		var checksum : = method_list.hash()
		var result = _get_class_cache(obj)
		if checksum == result.get("checksum",0):
			return result.methods
		for method_info in method_list:
			var params : = {}
			if parse_method(method_info.name, params):
				result.methods[method_info.name] = params
		result.checksum = checksum
		return result.methods
	
	
	static func parse_method(method :String, params :Dictionary = { priority = DEF_PRIORITY }):
		if method in _CACHES.methods:
			var cached :Dictionary = _CACHES.methods[method]
			for key in cached:
				params[key] = cached[key]
			params.priority = int(params.get("priority",str(DEF_PRIORITY)))
			return true
		
		var regex = _get_method_regex()
		var parsed = regex.search(method)
		if parsed == null:
			params.priority = int(params.get("priority",str(DEF_PRIORITY)))
			return false
		
		for field in parsed.names:
			if not(field in params):
				var value :String = parsed.get_string(field)
				if not value.empty():
					params[field] = value
		
		if params.get("func_name","").empty():
			params.func_name = method
		params.priority = int(params.get("priority",str(DEF_PRIORITY)))
		
		_CACHES.methods[method] = params.duplicate(true)
		
		return true
	
	
	static func _get_class_cache(obj :Object) -> Dictionary:
		var class_key = obj.get_script()
		if class_key == null:
			class_key = obj.get_class()
		var result :Dictionary = _CACHES.classes.get(class_key, { methods = {} })
		_CACHES.classes[class_key] = result
		return result
	
	
	static func _get_method_regex() -> RegEx:
		var regex = _CACHES.get("regex")
		if regex == null:
			regex = RegEx.new()
			regex.compile( FUNC_PATTERN.format({ priority="(?<priority>[0-9]*)", func_name="(?<func_name>.+)" }) )
		_CACHES.regex = regex
		return regex



class FRef:
	enum {
		IDX_OBJ,
		IDX_FUNC,
		IDX_PRIOR
	}
	const _OPT : = { autosort = true }
	
	static func set_autosort(value :bool) -> void:
		_OPT.autosort = value
	
	static func make(obj :Object, method :String, priority :int = DEF_PRIORITY) -> Array:
		return [weakref(obj), method, priority]
	
	static func call_first(fref_list :Array, args :Array):
		var fref :Array = get_first_valid(fref_list)
		if fref != null:
			return call_func(fref, args)
	
	static func call_func(fref :Array, args :Array):
		if not is_valid(fref):
			return null
		var obj :Object = get_obj(fref)
		var fname :String = fref[IDX_FUNC]
		return obj.callv(fname, args)
	
	static func call_func_deferred(fref :Array, args :Array):
		if not is_valid(fref):
			return null
		var obj :Object = get_obj(fref)
		var fname :String = fref[IDX_FUNC]
		args.push_front(fname) # first arg for "call_deferred"
		obj.callv("call_deferred", args)
		
	static func fix_list(fref_list :Array) -> void:
		for i in range(fref_list.size()-1, -1, -1):
			var fref :Array = fref_list[i]
			if not is_valid(fref):
				fref_list.remove(i)
	
	static func is_valid(fref :Array) -> bool:
		var obj : = get_obj(fref)
		if obj == null:
			return false
		if not(fref[IDX_FUNC] is String) or fref[IDX_FUNC].empty():
			return false
		if not obj.has_method(fref[IDX_FUNC]):
			return false
		return true
	
	static func sort_list(fref_list :Array) -> void:
		fref_list.sort_custom(FRef, "_compare")
	
	static func _compare(fref1, fref2) -> bool:
		return fref1[IDX_PRIOR] > fref2[IDX_PRIOR]
	
	static func get_obj(fref :Array) -> Object:
		if fref.empty() or (not fref[IDX_OBJ] is WeakRef):
			return null
		var obj :Object = fref[IDX_OBJ].get_ref()
		if not is_instance_valid(obj):
			fref[IDX_OBJ] = null
			obj = null
		return obj
	
	static func get_first_valid(fref_list :Array):
		while (not fref_list.empty()):
			var fref :Array = fref_list.front()
			if is_valid(fref):
				return fref
			fref_list.pop_front()
		return null
	
	static func find(fref_list :Array, obj :Object, method :String):
		for fref in fref_list:
			if (get_obj(fref) == obj) and (fref[IDX_FUNC] == method):
				return fref
		return null
	
	static func add_to_list(fref_list :Array, obj :Object, method :String, priority :int = DEF_PRIORITY) -> void:
		var fref = find(fref_list, obj, method)
		if fref == null:
			fref = make(obj, method, priority)
			fref_list.append(fref)
		else:
			fref[IDX_PRIOR] = priority
		fix_list(fref_list)
		if _OPT.autosort:
			sort_list(fref_list)

	
	static func remove_from_list(fref_list :Array, obj :Object, method :String = "") -> void:
		if method.empty():
			for fref in fref_list:
				if get_obj(fref) == obj:
					fref[IDX_OBJ] = null
			fix_list(fref_list)
		else:
			var fref = find(fref_list, obj, method)
			fref_list.erase(fref)



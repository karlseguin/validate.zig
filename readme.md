An data validator for Zig

This is a work in progress and fairly opinionated. It's currently focused around validating JSON data. It supports nested objects and arrays, and attempts to generate validation messages that are both user-friendly (i.e. can be displayed to users as-is) and developer-friendly (e.g. can be customized as needed).

# Quick Example
The first step is to create "validators" using a `Builder`:

```zig
const Builder = @import("validate").Builder;

// If we want to validate a "movie" that looks like:
// {"title": "A Movie", "year": 2000, "score": 8.4, "tags": ["drama", "sci-fi"]}

// First, we create a new builder. In more advanced cases, we can pass application-specific data
// into our validation (so that we can do more advanced app-specific logic). In this example, we
// won't use a state, so our builder takes a state type of `void`:
var builder = try validate.Builder(void).init(allocator);

// Validators are often long lived (e.g. the entire lifetime of the program), so deinit'ing the builder
// here might not be what you want.
// defer builder.deinit(allocator);

// Next we use our builder to create a validator for each of the individual fields:
var year_validator = builder.int(.{.min = 1900, .max = 2050, .required = true});
var title_validator = builder.string(.{.min = 2, .max = 100, .required = true});
var score_validator = builder.float(.{.min = 0, .max = 10});
var tag_validator = builder.string(.{.choices = &.{"action", "sci-fi", "drama"}});

// An array validator is like any other validator, except the first parameter is an optional
// validator to apply to each element in the array.
var tagsValidator = builder.array(&tagValidator, .{.max = 5});

// An object validate is like any other validator, except the first parameter is a list of
// fields, each field containing the input key and the validator:
const movieValidator = builder.object(&.{
    builder.field("year", year_validator),
    builder.field("title", title_Validator),
    builder.field("score", score_validator),
    builder.field("tags", tags_validator),
}, .{});
```

Validators are thread-safe. 

With validators defined, we can validate data. Validation happens (1) on an input, (2) using a validator built with a Builder and (3) with a validation context. The context collects errors and maintains various internal state (e.g. when validating values in an array, it tracks the array index so that a more meaningful error message can be generated).

A context is not thread safe.

```zig
const Context = @import("validate").Context;

// validate.zig supports arbitrary application state, hence Context is a generic (and takes a type) and the 3rd parameter to init is the state. We'll cover this later. For now we use void and a void state of {}:
var context = try validate.Context(void).init(allocator, .{.max_errors = 10, .max_nesting = 4}, {});
defer context.deinit();

const jsonData = "{\"year\": \"nope\", \"score\": 94.3, \"tags\": [\"scifi\"]}";
switch (movieValidator.validateJsonS(jsonData, &context)) {
    .ok => {},
    .err => |err| return err,
    .json => // TODO: json was not valid
    .invalid => |invalid| {
        var arr = std.ArrayList(u8).init(t.allocator);
        defer arr.deinit();
        try std.json.stringify(invalid.errors, .{.emit_null_optional_fields = false}, arr.writer());
        std.debug.print("{s}", .{arr.items});
        return;
    }
}

// On success, validateJsonS returns a thin wrapper around std.json.Value
// which lets us get values:

const title = movie.string("title").?
// ...
```

The above sample outputs the validation errors as JSON to stdout. Given the `jsonData` in the snippet, the output would be:
```json
[
    {"field": "year" ,"code": 4, "err": "must be an int"},
    {"field": "title" ,"code": 1, "err": "is required"},
    {"field": "score", "code": 14, "err": "cannot be greater than 10", "data": {"max": 1.0e+01}},
    {"field": "tags.0", "code": 10, "err": "must be one of: action, sci-fi, drama", "data": {"valid": ["action", "sci-fi", "drama"]}}
]
```

# Concepts

## Builder
The `validate.Builder` is used to create validators. The full Builder API is described later. Validators are optimized for long-term / repeated use, so the Builder does more setup than might initially be obvious. 

Validators don't require a huge amount of allocations, but some of the allocations could be considered subtle. For example, if a "name" validator gets placed in a "user" object, a "user.name" value is created as part of the "Builder" phase. Doing this upfront once mean that the "user.name" field is ready to be used (and re-used) when validation errors happen.

All this is to say that the Builder's `init` takes the provided `std.mem.Allocator` and creates and uses an ArenaAllocator. Individual validators do not have a `deinit` function. Only the `Builder` itself does.

In many applications, a single Builder will be created on startup and can be freed on shutdown.

## Context
When it comes time to actually validate data, a `validate.Context` is created. The context collects errors and the internal state necessary for validation as well as for generating meaningful errors.

In the simplest case, a context is created (or taken from a validate.Pool), and passed to validator. However, in more advanced cases, particularly when a custom function is given to a validator, applications might interact with the context directly, either to access parts of the input and/or add custom validation errors.

When validating, this library attempts to minimize memory allocations as much as possible. In some cases, this is not possible. Specifically, when an error is added for an array value, the field name is dynamic, e.g, "user.favorites.4".

## State
While this library has common validation rules for things like string length, min and max values, array size, etc., it also accepts custom validation functions. Sometimes these functions are simple and stateless. In other cases it can be desirable to have some application-specific data. For example, in a multi-tenancy application, data validation might depend on tenant-specific configuration.

The `Builder` and `Context` types explored above are generic functions which return a `Builder(T)` and `Context(T)`. When the `validateJsonS` function is called, a `state T` is provided, which is then passed to custom validation functions:

```zig
// Our builder will build validators that expect a `*Custom` instance
// (`Custom` is a made-up application type)
var builder = try validate.Builder(*Custom).init(allocator);

// Our nameValidator specifies a custom validation function, `validateName`
var nameValidator = builder.string({.required = true, .function = validateName})
...


fn validateName(value: []const u8, context: *Context(*Customer)) !?[]const u8 {
    const customer = context.state;
    // can do custom validation based on the customer
}
```

We then specify the same `*Customer` type when creating our Context and provide the instance:

```zig
const customer: *Customer = // TODO: the current customer
var context = try Context(*Customer).init(allocator, .{}, customer);
```

## Errors
Generated errors are meant to be both user-friendly and developer-friendly. At a minimum, every error has a `code` and `err` field. `err` is a user-safe English string describing the error. It's "user-safe" because the errors are still generic, such as "must have no more than 10 items" as opposed to a more app-specific "cannot pick more than 10 addons".

The `code` is an integer that is unique to each type of error. For example, a `code=1` means that a required field was missing.

Most errors will also contain a `field` string. This is the full field name, including nesting and zero-based array indexes, such as `user.favorite.2.id`. This field is optional - sometimes validation errors don't belong to a specific field.

Some errors also have a `data` object. The inclusion and structure of the `data` object is specific to the `code`. For example, a error with `code=1` (required) always has a null `data` field (or no data field if the errors are serialized with the `emit_null_optional_fields = true` option). An error with `code=8` (string min length) always has a `data: {min: N}`.

Between the `code`, `data` and `field` fields, developers should be able to programmatically consume and customize the errors.

## Typed
Validation of data happens by calling `validateJsonS` on an `object` validator. This function returns a `validate.Typed` instance which is a thin wrapper around `std.json.Value`.

The goal of `validate.Typed` is to provide a user-friendly API to extract the input data safely.

The returned `Typed` object and its data are only valid as long as the `validate.Context` that was passed into `validateJson` is.

## Custom Functions
Most validators accept a custom function. This custom function will only be called if all other validators pass. Importantly, if a value is `null` and `required = false`, the custom validator **is** called with `null`.

The signature of these functions is:

```zig
*const fn(value: ?T, context: Context(S)) !?T
```

For an integer validator, `T` is `i64`. For a float validator, `T` is `f64` and so on.

There are a few important things to note about custom validators. First, as already mentioned, if the value is not required and is null, the custom validator **is** called with null. Thus, the type of `value` is `?T`. Second, custom validators can return a new value to replace the existing one, hence the return type of `?T`. Returning `null` will maintain the existing value. Finally, the provided `context` is useful for both simple and complex cases. At the very least, you'll need to call `context.add(...)` to add errors from your validator.

# API
## Builder
The builder is used to create and own validators. When `deinit` is called on the builder, all of the validators created from it are no longer valid.

```zig
var builder = try validate.Builder(void).init(allocator);

// The builder must live as long as any validator it creates.
// defer builder.deinit()
```

### Int Validator
An int validator is created via the `builder.int` function. This function takes a configuration structure. The full possible configuration, with default values, is show below:

```zig
const age_validator = builder.int(.{
    // whether the value is required or not
    .required = false,

    // the minimum allowed value (inclusive of min), null == no limit
    .min = null, // i64

    // the maximum allowed value (inclusive of max), null == no limit
    .max = null, // i64

    // a custom validation function that will receive the value to validate
    // along with a validation.Context.
    function: ?*const fn(value: ?i64, context: *Context(S)) anyerror!?i64 = null,
});
```

In rare cases (e.g. OOM) `builder.int` can panic. `builder.tryInt` function can be used to return an ErrorSet which can be caught/unwrapped/propagated.

Typically, this validator is invoked as part of an object validator. However, it is possible to call `validateJsonValue` directly on this validator by providing a `std.json.Value` and a validation Context.

### Float Validator
A float validator is created via the `builder.float` function. This function takes a configuration structure. The full possible configuration, with default values, is show below:

```zig
const rating_validator = builder.float(.{
    // whether the value is required or not
    .required = false,

    // the minimum allowed value (inclusive of min), null == no limit
    .min = null, // f64

    // the maximum allowed value (inclusive of max), null == no limit
    .max = null, // f64

    // when false, integers will be accepted and converted to an f64
    // when true, if an integer is given, validation will fail
    .strict = false, 

    // a custom validation function that will receive the value to validate
    // along with a validation.Context.
    function: ?*const fn(value: ?f64, context: *Context(S)) anyerror!?f64 = null,
});
```

In rare cases (e.g. OOM) `builder.float` can panic. `builder.tryFloat` function can be used to return an ErrorSet which can be caught/unwrapped/propagated.

Typically, this validator is invoked as part of an object validator. However, it is possible to call `validateJsonValue` directly on this validator by providing a `std.json.Value` and a validation Context.

### Bool Validator
A bool validator is created via the `builder.bool` function. This function takes a configuration structure. The full possible configuration, with default values, is show below:

```zig
const enabled_validator = builder.boolean(.{
    // whether the value is required or not
    .required = false,

    // a custom validation function that will receive the value to validate
    // along with a validation.Context.
    function: ?*const fn(value: ?bool, context: *Context(S)) anyerror!?bool = null,
});
```

In rare cases (e.g. OOM) `builder.bool` can panic. `builder.tryBool` function can be used to return an ErrorSet which can be caught/unwrapped/propagated.

Typically, this validator is invoked as part of an object validator. However, it is possible to call `validateJsonValue` directly on this validator by providing a `std.json.Value` and a validation Context.

### String Validator
A string validator is created via the `builder.string` function. This function takes a configuration structure. The full possible configuration, with default values, is show below:

```zig
const name_validator = builder.string(.{
    // whether the value is required or not
    .required = false,

    // the minimum length (inclusive of min), null == no limit
    .min = null, // usize

    // the maximum length(inclusive of max), null == no limit
    .max = null, // usize

    // a list of valid choices, this list is case sensitive
    .choices = null, // []const []const u8

    // a regular expression pattern, currently using POSIX regex, but likely to change in the future
    .pattern = null // []const u8

    // a custom validation function that will receive the value to validate
    // along with a validation.Context.
    function: ?*const fn(value: ?[]const u8, context: *Context(S)) anyerror!?[]const u8 = null,
});
```

In rare cases (e.g. OOM) `builder.string` can panic. `builder.tryString` function can be used to return an ErrorSet which can be caught/unwrapped/propagated.

Typically, this validator is invoked as part of an object validator. However, it is possible to call `validateJsonValue` directly on this validator by providing a `std.json.Value` and a validation Context.

### Any Validator
A type-less validator is created via `builder.any` function. Unlike all other validators, this validator does not validate the type of the value. This validator is useful when the type of a field is only known at runtime and a custom validation function is used.

This function takes a configuration structure. The full possible configuration, with default values, is show below:

```zig
const default_validator = builder.any(.{
    // whether the value is required or not
    .required = false,

    // a custom validation function that will receive the value to validate
    // along with a validation.Context.
    function: ?*const fn(value: ?[]json.Value, context: *Context(S)) anyerror!?json.Value = null,
});
```

In rare cases (e.g. OOM) `builder.any` can panic. `builder.tryAny` function can be used to return an ErrorSet which can be caught/unwrapped/propagated.

Typically, this validator is invoked as part of an object validator. However, it is possible to call `validateJsonValue` directly on this validator by providing a `std.json.Value` and a validation Context.

### Array Validator
An array validator is created via the `builder.array` function. The array validator can validate the array itself (e.g. it's length) as well as each item within in. As such, this function takes both an optional validator to apply to the array values, as well as a configuration structure. The full possible configuration, with default values, is show below:

```zig
// name_validator will be applies to each value in the array. 
// null can also be provided, in which case array items will not be validated
// (but the array itself will still be validated based on the provided configuration)
const names_validator = builder.array(name_validator, .{
    // whether the value is required or not
    .required = false,

    // the minimum length (inclusive of min), null == no limit
    .min = null, // usize

    // the maximum length(inclusive of max), null == no limit
    .max = null, // usize
});
```

In rare cases (e.g. OOM) `builder.array` can panic. `builder.tryArray` function can be used to return an ErrorSet which can be caught/unwrapped/propagated.

Typically, this validator is invoked as part of an object validator. However, it is possible to call `validateJsonValue` directly on this validator by providing a `std.json.Value` and a validation Context.

### Object Validator
The object validator is similar but also different from the others. Like the other validators, it's created via the `builder.object` function. And, like the other validators, it takes a configuration object that defines how the object value itself should be validated.

However, unlike the other validators (but a little like the array validator), `builder.object` takes a `name => validator` map which defines the validator to use for each value in the object.

```zig
var user_validator = builder.object(name_validator, &.{
    builder.field("age", age_validator),
    builder.field("name", name_validtor),
}, .{
    // whether the value is required or not
    .required = false,

    // a custom validation function that will receive the value to validate
    // along with a validation.Context
    function: ?*const fn(value: ?json.ObjectMap, context: *Context(S)) anyerror!?json.ObjectMap = null,
});
```

In rare cases (e.g. OOM) `builder.object` can panic. `builder.tryObject` function can be used to return an ErrorSet which can be caught/unwrapped/propagated.

One created, either `validateJsonS` or `validateJsonV` are used to kick-off validation. `validateJsonS` takes a `[]const u8`. `validateJsonV` takes an `?std.json.Value`.

These return a `validate.Result` which is a tagged union:

```zig
const input = switch (user_validator.validateJsonS("...", context)) {
    .ok => |input| input,
    .json => |err| // the json could not be parsed
    .err => |err| // some internal validation error (e.g. allocation failure)
    .invalud => |invalid| {
        const error = invalid.errors;
        // errors can be serialized to JSON
    }
}
```

## Context
In simple cases, the context is an after thought: it is created and passed to `validateJsonS` or `validateJsonV`. 

### Creation
To create a context with no custom state, use:

```zig
var context = validate.Context(void).init(allocator, .{
    .max_errors = 20,
    .max_nesting = 10,
}, {});
```

To create a context with custom state, say a `*Customer`, use:

```zig
var context = validate.Context(*Customer).init(allocator, .{
    .max_errors = 20,
    .max_nesting = 10,
}, the_customer);
```

`max_errors` limits how many errors will be collected. Additional errors will be silently dropped. (This is an optimization so that we can statically allocate an array to hold errors, which makes more sense since validate.Pool provides a re-usable pool of validation contexts).

`max_nesting` limits the depth of the object to validate, specifically with respect to arrays. Object and array validators can be nested in any combination, but array validators are difficult as they introduce dynamic field names (e.g. "users.5.favorites.193.name"). The context must keep a stack of array indexes. This is statically allocated (the stack is merely an []usize, so setting this to a larger value should be fine).

### Pool
A thread-safe re-usable pool of Contexts can be created and used:

```zig
var pool = validate.Pool(S).init(allocator, .{
    // how many contexts to keep in the pool
    .size = 50, // u16

    // Configuration for each individual context
    .max_errors = 20,
    .max_nesting = 10,
})
```

Contexts can thus be acquired from the pool and released back into the pool:

```zig
var context = try pool.acquire();
defer pool.release(context);
```

The pool is non-blocking. If empty, a context is dynamically created. The pool will never grow beyond the configured sized.

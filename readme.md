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

// Next we use out builder to create a validator for each of the individual fields:
var yearValidator = builder.int(.{.min = 1900, .max = 2050, .required = true});
var titleValidator = builder.string(.{.min = 2, .max = 100, .required = true});
var scoreValidator = builder.float(.{.min = 0, .max = 10});

// We can validate nested objects and arrays
var movieTags = [_][]const u8{"action", "sci-fi", "drama"};
var tagValidator = builder.string(.{.choices = &movieTags});

// An array validator is like any other validator, except the first parameter is an optional
// validator to apply to each element in the array.
var tagsValidator = builder.array(&tagValidator, .{.max = 5});

// An object validate is like any other validator, except the first parameter is a list of
// fields which is the name and the validator to apply to it:
const movieValidator = builder.object(&.{
    builder.field("year", &yearValidator),
    builder.field("title", &titleValidator),
    builder.field("score", &scoreValidator),
    builder.field("tags", &tagsValidator),
}, .{});
```

Our validators are thread-safe. We use them along with a validation Context to validate data:

```zig
const Context = @import("validate").Context;

// The last parameter of our Context init is the state value to pass into any custom validation
// functions we have. Above, our Builder had a state of `void`, so our Context also has a state of `void`
// and we pass a void state value, `{}`, as the last parameter:

var context = try validate.Context(void).init(allocator, .{.max_errors = 10, .max_nesting = 4}, {});
defer context.deinit();

const jsonData = "{\"year\": \"nope\", \"score\": 94.3, \"tags\": [\"scifi\"]}";
var movie = movieValidator.validateJson(jsonData, &context);
if (!context.isValid()) {
    // use context.errors() to get an array of errors, which you can serialize to json:

    var arr = std.ArrayList(u8).init(t.allocator);
    defer arr.deinit();
    try std.json.stringify(context.errors(), .{.emit_null_optional_fields = false}, arr.writer());
    std.debug.print("{s}", .{arr.items});
    return;
}

// the validateJson function on an objectValidator returns a thin wrapper around std.json.Value
// which lets us get values:

const title = movie.string("title").?
// ...
```

The above sample outputs the validation errors as JSON to stdout. Given the `jsonData` provided, the output would be:
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
When it comes time to actually validate data, a `validate.Context` is created. This object maintains internal state (like the array index that we're currently at). More importantly, it exposes an `isValid()` and `errors()` function which can be used to determine if validation was successful and, if not, get a list of errors.

The `add` function is used to add errors from within a custom validation function.

When validating, this library attempts to minimize memory allocations as much as possible. In some cases, this is not possible. Specifically, when an error is added for an array value, the field name is dynamic, e.g, "user.favorites.4". Like the Builder, the Context also creates and uses an ArenaAllocator. This allocator is available to custom validation functions as `context.allocator`.

## State
While this library has common validation rules for things like string length, min and max values, array size, etc., it also accepts custom validation functions. Sometimes these functions are simple and stateless. In other cases it can be desirable to have some application-specific data. For example, in a multi-tenancy application, data validation might depend on tenant-specific configuration.

The `Builder` and `Context` types explored above are actually generic functions which return a `Builder(T)` and `Context(T)`. When the `validateJson` function is called, a `state T` is provided, which is then passed to custom validation functions:

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
Generated errors are meant to be both user-friendly and developer-friendly. At a minimum, every error has a `code` and `err` field. `err` is a user-safe English string describing the error. It's "user-safe" because the errors are still generic, such as "must no more than 10 items" as opposed to a more app-specific "cannot pick more than 10 addons".

The `code` is an integer that is unique to each type of error. For example, a `code=1` means that a required field was missing.

Most errors will also contain a `field` string. This is the full field name, including nesting and zero-based array indexes, such as `user.favorite.2.id`. This field is optional - sometimes validation errors don't belong to a specific field.

Some errors also have a `data` object. Whether or not an error has a `data` object, the type of fields in `data` and their meaning is specific to the `code`. For example, a error with `code=1` (required) always has a null `data` field (or no data field if the errors are serialized with the `emit_null_optional_fields = true` option). An error with `code=8` (string min length) always has a `data: {min: N}`.

Between the `code`, `data` and `field` fields, developers should be able to programmatically consume and customize the errors.

## Typed
Validation of data happens by calling `validateJson` on an `object` validator. This function returns a `validate.Typed` instance which is a thin wrapper around `std.json.Value`.

The goal of `validate.Typed` is to provide a user-friendly API to extract the input data safely.

The returned `Typed` object and its data are only valid as long as the `validate.Context` that was passed into `validateJson` is.

# API
Dogfooding this a little before first

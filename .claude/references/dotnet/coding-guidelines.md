# Coding style

## Summary

- [Naming conventions](#naming-conventions)
  - [Class names](#class-names)
  - [Interfaces](#interfaces)
  - [Variable names](#variable-names)
  - [Route names](#route-names)
  - [Abbreviations and acronyms](#abbreviations-and-acronyms)
- [Lambda expressions](#lambda-expressions)

  - [Parameter names](#paramtere-names)
  - [Split chained methods with lambda expressions in separate line](#split-chained-methods-with-lambda-expressions-in-separate-line)
  - [LINQ conventions](#linq-conventions)
    - [Use meaningful names for query variables](#use-meaningful-names-for-query-variables)
    - [Separate multiple `&&` from one `Where` statement in multiple `Where` statements.](#separate-multiple--from-one-where-statement-in-multiple-where-statements)
    - [ Use `Where` statement instead of writing condition in `Single`, or `First`](#use-where-statement-instead-of-writing-condition-in-single-or-first)
    - [ Prefer using `async` LINQ query when querying database](#prefer-using-async-linq-query-when-querying-database))
    - [Prefer using foreach loop over LINQ foreach](#prefer-using-foreach-loop-over-linq-foreach)
    - [Place `new` keyword in new line](#place-new-keyword-in-new-line)
    - [From database only select data which will be used](#from-database-only-select-data-which-will-be-used)
    - [Do not use `Single` when fetching entities by their `primary key` from database](#do-not-use-single-when-fetching-entities-by-their-primary-key-from-database)

- [Layout conventions](#layout-conventions)
  - [Use file scoped namespaces](#use-file-scoped-namespaces)
  - [Write only one statement per line](#write-only-one-statement-per-line)
  - [Write only one declaration per line](#write-only-one-declaration-per-line)
  - [Use compound assignment](#use-compound-assignment)
  - [Match namespaces to folder structure](#match-namespaces-to-folder-structure)
  - [`using` directives](#using-directives)
  - [Use simple `using` declaration over `using` statement with curly braces](#use-simple-using-declaration-over-using-statement-with-curly-braces)
  - [Leave one blank line before return statement in method](#leave-one-blank-line-before-return-statement-in-method)
  - [Never use 2 empty lines in a row](#never-use-2-empty-lines-in-a-row)
  - [Private methods should be last in file](#private-methods-should-be-last-in-file)
  - [Separate type members and methods with a single blank line, except private fields](#separate-type-members-and-methods-with-a-single-blank-line-except-private-fields)
  - [Separate code into logically-related blocks](#separate-code-into-logically-related-blocks)
  - [Avoid using `else`](#avoid-using-else)
  - [Indentation](#indentation)
  - [Create variables when you need them](#create-variables-when-you-need-them)
- [MediatR conventions](#mediatr-conventions)
  - [Use only one `SaveChanges` in handler](#use-only-one-savechanges-in-handler)
  - [Always validate request](#always-validate-request)
  - [Place `Handler`, `Request` and `Response` in the same file](#place-handler-request-and-response-in-the-same-file)
- [Braces](#braces)
- [Other](#other)
  - [Always use implicit typing (`var`) for local variables](#always-use-implicit-typing-var-for-local-variables)
  - [Extract complicated expression to a variable](#extract-complicated-expression-to-a-variable)
  - [Use `foreach` loop over `for` loop when is possible](#use-foreach-loop-over-for-loop-when-is-possible)
  - [Avoid initializing collections in loops(`for`, `foreach`, `while`)](#avoid-initializing-collections-in-loopsfor-foreach-while)
  - [IOptions](#ioptions)
  - [Add changes to database context just before calling `SaveChanges`](#add-changes-to-database-context-just-before-calling-savechanges)
  - [Avoid using helper lists](#avoid-using-helper-lists)
  - [Do not add meaningless comments](#do-not-add-meaningless-comments)
  - [Prefer null coalescing expressions to ternary operator checking](#prefer-null-coalescing-expressions-to-ternary-operator-checking)
  - [Prefer assignments and return statements to use a ternary conditional, over if-else statement](#prefer-assignments-and-return-statements-to-use-a-ternary-conditional-over-if-else-statement)
  - [Prefer simplified conditional expressions](#prefer-simplified-conditional-expressions)
  - [Prefer simplified interpolated strings](#prefer-simplified-interpolated-strings)
  - [Prefer fields not to be prefaced with `this.`](#prefer-fields-not-to-be-prefaced-with-this)
  - [Git branch naming](#git-branch-naming)

## Naming conventions

### Class Names

Use `PascalCasing` for class names and method names.

```C#
public class Example
{
    public void ExampleMethod()
    {
    }
}
```

### Interfaces

Use `PascalCasing` for interface name and prefix the name with an `I`.

```C#
public interface IExampleInterface
{
}
```

### Variable Names

Use `camelCasing` when naming local variables and method arguments.

```C#
public class Example
{
    public void ExampleMethod(string exampleArgument)
    {
        var exampleLocalVariable = ...
    }
}
```

Use `camelCasing` when naming `private` or internal fields, and prefix them with `_`.

```C#
public class Example
{
    private readonly ILogger<Example> _logger;

    public Example(ILogger<Example> logger)
    {
        _logger = logger;
    }
}
```

Use `PascalCasing` when naming `public` members of types, such as fields, properties, events, methods, and local functions.

```C#
public class Example
{
    public string Name {get; set;}
}
```

### Route names

Prefer using `kebab-casing` for route names.

```C#
[HttpGet("get-all-blogs")]
```

### Abbreviations and acronyms

Avoid using **abbreviations**.  
**Exceptions**: abbreviations commonly used as names, such as **Id**, **Xml**, **Uri**.

When using acronyms only first letter is uppercase.

```C#
// bad
var personOIB = 01234567891;

// good
var personOib = 19876543210;
```

## Lambda expressions

### Parameter names

Use letter `x` as parameter name for lambda expressions.

If you have nested lambdas, in inner lambdas use letters `y` and `z`.

```C#
// bad
var blogsWithPostRatingHigherThanThree = blogs
    .Where(b => b.Posts
        .Any(p => p.Rating > 3))
    .ToList();

// good
var blogsWithPostRatingHigherThanThree = blogs
    .Where(x => x.Posts
        .Any(y => y.Rating > 3))
    .ToList();
```

### Split chained methods with lambda expressions in separate line

If you invoke a chain of methods with lambda expressions, split each invocation onto its own line.

```C#
// bad
var evenNumbers = numbers.Where(x => x % 2 == 0).ToList();

// good
var evenNumbers = numbers
    .Where(x => x % 2 == 0)
    .ToList();
```

### LINQ conventions

#### Use meaningful names for query variables

The following example uses zagrebCustomers for customers who are located in Zagreb.

```C#
var zagrebCustomers = await dbContext.Customers
    .Where(x => x.City == "Zagreb")
    .ToListAsync();
```

#### Separate multiple `&&` from one `Where` statement in multiple `Where` statements.

```C#
// bad
var filteredNumbers = numbers
    .Where(x => x % 7 == 0 && x > 200)
    .ToList();

// good
var filteredNumbers = numbers
    .Where(x => x % 7 == 0)
    .Where(x => x > 200)
    .ToList();
```

#### Use `Where` statement instead of writing condition in `Single`, or `First`.

```C#
// bad
var numberDivisibleByTen = numbers
    .FirstOrDefault(x => x % 10 == 0);

// good
var numberDivisibleByTen = numbers
    .Where(x => x % 10 == 0)
    .FirstOrDefault();
```

#### Prefer using `async` LINQ query when querying database

```C#
var blogs = await dbContext.Blogs
    .Where(x => x.Rating > 3)
    .ToListAsync();
```

#### Prefer using `foreach` loop over LINQ foreach

```C#
// bad
items.ToList().ForEach(x => x.DoStuff());

// good
foreach(var item in items)
{
    item.DoStuff();
}
```

#### Place `new` keyword in new line

When creating new object instance in Select, add `new` keyword and class name to new line and indent it one `tab` more than `Select`.

Example: Fetch Blog name and Author name.

```C#
// bad
// loading whole object from database and using Include
var blogs = await dbContetxt.Blogs
    .Include(x => x.Author)
    .ToListAsync();

var blogData = blogs
    .Select(x =>
        new BlogData
        {
            Name = x.Name,
            AuthorName = x.Author.FirstName
        })
    .ToListAsync();

// bad
// new keyword in the same line as Select
var blogData = await dbContetxt.Blogs
    .Select(x => new BlogData
    {
        Name = x.Name,
        AuthorName = x.Author.FirstName
    })
    .ToListAsync();

// good
var blogData = await dbContetxt.Blogs
    .Select(x =>
        new BlogData
        {
            Name = x.Name,
            AuthorName = x.Author.FirstName
        })
    .ToListAsync();
```

#### From database only select data which will be used

There is no need to fetch whole object unless you are going to update it.

Avoid using `Include`. Use `Select` instead.

#### Do not use `Single` when fetching entities by their `primary key` from database

## Layout conventions

### Use file scoped namespaces

```C#
// bad
namespace Api.Entity
{
    public class Example
    {
        ...
    }
}

// good
namespace Api.Entity;

public class Example
{
    ...
}
```

### Write only one statement per line

```C#
// bad
blog1.Name = "blog1"; blog2.Name = "blog2";

// good
blog1.Name = "blog1";
blog2.Name = "blog2";
```

### Write only one declaration per line

```C#
// bad
var x = 0, y = 0;

// good
var x = 0;
var y = 0;

```

### Use compound assignment

```C#
// bad
x = x + 5;

// good
x += 5;
```

### Match namespaces to folder structure

```C#
// bad
// file path: Example/Convention/C.cs
using System;

namespace Example;

class C
{
}

// good
// file path: Example/Convention/C.cs
using System;

namespace Example.Convention;

class C
{
}
```

### `using` directives

Prefer `using` directives to be placed outside the namespace.

Sort `System.*` `using` directives alphabetically, and place them before other using directives.

### Use simple `using` declaration over `using` statement with curly braces

```C#
// bad
using (var a = b)
{
    ...
}

// good
using var a = b;
```

```C#
// bad
using System.Collections.Generic;
using Octokit;
using System.Threading.Tasks;

// good
using System.Collections.Generic;
using System.Threading.Tasks;
using Octokit;
```

### Leave one blank line before return statement in method

```C#
// bad
public int ReverseInteger(int number)
{
    var reversedNumber = 0;
    while (num > 0)
    {
        reversedNumber = result * 10 + num % 10;
        num /= 10;
    }
    return reversedNumber;
}

// good
public int ReverseInteger(int number)
{
    var reversedNumber = 0;

    while (num > 0)
    {
       reversedNumber = result * 10 + num % 10;
       num /= 10;
    }

    return reversedNumber;
}
```

### `Never` use 2 empty lines in a row.

```C#
// bad
public int ReverseInteger(int number)
{
    var reversedNumber = 0;
    while (num > 0)
    {
        reversedNumber = result * 10 + num % 10;
        num /= 10;
    }

    return reversedNumber;
}

// good
public int ReverseInteger(int number)
{
    var reversedNumber = 0;

    while (num > 0)
    {
       reversedNumber = result * 10 + num % 10;
       num /= 10;
    }

    return reversedNumber;
}

```

### Private methods should be last in file

### Separate type members and methods with a single blank line, except private fields

```C#
// bad
public class Blog
{
    private string _authorName;

    private string _authorLastname;

    public Blog()
    {
    }
    public DoSomething()
    {
    }
}

// good
public class Blog
{
    private string _authorName;
    private string _authorLastname;

    public Blog()
    {
    }

    public DoSomething()
    {
    }
}
```

### Separate code into logically-related blocks

Use single blank lines to split method bodies into logically-related blocks.

Separate unrelated control flow blocks with a blank line.

```C#
// bad
if (value == 0)
{
}
else if (value == 1)
{
}
if (defaultValue == 0)
{
}

// good
// Separate independent `if` clauses with a blank line.
// This avoids confusion between independent conditional logic and an `else if` condition.
if (x < 0)
{
}
else if (x > 1)
{
}

if (y != 0)
{
}
```

### Avoid using `else`

Always `return` before if possible. This reduces nesting and makes to code easier to follow.

```C#
// bad
if (isValid)
{
    // Some code, happy path goes here
}
else
{
   return; // or throw new Exception("not valid");
}

// good
if (!isValid)
{
   return; // or throw new Exception("not valid");
}

// Some code, happy path goes here
```

### Indentation

If continuation lines are not indented automatically, indent them one tab (four spaces).

If a single statement must include a long chain or nested tree of sub-statements, split the line as follows:

    1.Place operators at the beginning of lines rather than the end of the previous line.
    2.Use indentation to clarify nesting relationships. When splitting a parenthesized sub-expression, indent it one more level than the previous line.
    3.Split related operations at the same level.

```C#
// bad
if (blog.Rating > 3 || blog.Posts.Count() < 10 || blog.Author.Age < 30)
{
}

// good
if (blog.Rating > 3
    || blog.Posts.Count() < 10
    || blog.Author.Age < 30)
{
}
```

Indent dotted invocations one level deeper than the root object. Place the dot for each invocation at the beginning of that line.

```C#
// bad
var blogsWithPostRatingHigherThanThree = blogs
    .Where(x => x.Posts
    .Any(y => y.Rating > 3))
    .ToList();

// bad
var blogsWithPostRatingHigherThanThree = blogs
                                        .Where(x => x.Posts
                                            .Any(y => y.Rating > 3))
                                        .ToList();

// good
var blogsWithPostRatingHigherThanThree = blogs
    .Where(x => x.Posts
        .Any(y => y.Rating > 3))
    .ToList();
```

### Create variables when you need them

```C#
// bad
var blogName = blogs
    .Where(x => x.Id == 1)
    .Select(x => x.Name)
    .First();

// some lines of code

var blogsWithSameName = blogs
    .Where(x => x.Name == blogName)
    .ToList();

// good
// some lines of code

var blogName = blogs
    .Where(x => x.Id == 1)
    .Select(x => x.Name)
    .First();

var blogsWithSameName = blogs
    .Where(x => x.Name == blogName)
    .ToList();
```

## MediatR conventions

### CommandQuery naming

Handlers should contain only Query and Command suffixed files.

Example: `GetBlogsQuery` query file

Example: `UpdateBlogNameCommand` command file

### Use only one `SaveChanges` in handler

Services should not call `SaveChanges`. Handler should save all changes created in services.

### Always validate request

### Place `Handler`, `Request` and `Response` in the same file

Example: `UpdateBlogNameCommand.cs` file

```C#
namespace Core.Handlers.Blog;

public class UpdateBlogNameCommand : RequestHandler<UpdateBlogNameRequest, UpdateBlogNameResponse>
{
    ...
}

public class UpdateBlogNameRequest
{
    ...
}

public class UpdateBlogNameResponse
{
    ...
}
```

## Braces

When using object/collection intializer avoid using `()`.

```C#
// bad
var person = new Person()
{
    Name = "Name"
};

// good
var person = new Person
{
    Name = "Name"
};
```

When creating object, assign all properties in object initializer.

```C#
// bad
var blog = new Blog
{
    Name = "blogName"
};

blog.Rating = 5;

// good
var blog = new Blog
{
    Name = "blogName",
    Rating = 5
}
```

Use `braces` around statements with control flow keywords (`if`, `else`, `while`, `for`, `foreach`), even if statement block is one line.

```C#
// bad
if (x > 10) return;

// good
if (x > 10)
{
    return;
}
```

## Other

### Always use implicit typing (`var`) for local variables

### Extract complicated expression to a variable

When you have complicated expression in if statement, it is better to add this expression to the variable and name this variable accordingly.

```C#
var list1AndList2ContainsSameElements = !list1.Except(list2).Any()
    && !list2.Except(list1).Any();

if (list1AndList2ContainsSameElements)
{
    ...
}
```

### Use `foreach` loop over `for` loop when is possible

### Avoid initializing collections in loops(`for`, `foreach`, `while`)

```C#
// bad
foreach(var number in numbers
    .Where(x => x % 2 == 0)
    .ToList())
{
    ...
}

// good
var filteredList = numbers
    .Where(x => x / 2 == 0)
    .ToList();

foreach(var number in filteredList)
{
    ...
}
```

### IOptions

Always use `IOptions` to provide strongly typed access to groups of related settings.

`appsetting,json`

```C#
{
  "MySettings": {
    "StringSetting": "My Value",
    "IntSetting": 23
  }
}

public class MySettings
{
    public string StringSetting { get; set; }
    public int IntSetting { get; set; }
}
```

In service configuration just add:

```C#
public static class ServiceConfiguration
{
    public static void AddServices(this IServiceCollection services, IConfiguration configuration)
    {
        var section = configuration.GetSection("MySettings");
        services.Configure<MySettings>(section);
    }
}
```

Injecting in class:

```C#
public class Example
{
    private readonly MySettings _options;

    public Example(IOptions<MySettings> options)
    {
        _options = optoins.Value;
    }
}
```

### Add changes to database context just before calling `SaveChanges`

```C#
// bad
await context.Blogs.AddAsync(blog);

var x = 10;

await context.SaveChangesAsync();
```

```C#
//good

var x = 10;

await context.Blogs.AddAsync(blog);
await context.SaveChangesAsync();
```

### Avoid using helper lists

Use `Select` or method with `yield return` instead.

```C#
// bad
var blogsData = new List<BlogData>();

foreach (var blog in blogs)
{
    var blogData = new BlogData
    {
        Name = blog.Name,
        Rating = blog.Rating
    };

    blogsData.Add(blogData);
}

// good
var blogsData = blogs
    .Select(x =>
        new BlogData
        {
            Name = x.Name,
            Rating = x.Rating
        })
    .ToList();
```

### Do not add meaningless comments

```C#
/// <param name="itemData">data for new item</param>
/// <returns>success result</returns>
```

### Prefer null coalescing expressions to ternary operator checking

```C#
// bad
var v = x != null ? x : y; // or
var v = x == null ? y : x;

// good
var v = x ?? y;
```

### Prefer assignments and return statements to use a ternary conditional, over if-else statement

```C#
// bad
string s;
if (expr)
{
    s = "hello";
}
else
{
    s = "world";
}

// good
var s = expr ? "hello" : "world";
```

### Prefer simplified conditional expressions

```C#
// bad
var result1 = M1() && M2() ? true : false;
var result2 = M1() ? true : M2();

// good
var result1 = M1() && M2();
var result2 = M1() || M2();
```

### Prefer simplified interpolated strings

```C#
// bad
var str = $"prefix {someValue.ToString()} suffix";

// good
var str = $"prefix {someValue} suffix";
```

### Prefer fields **not** to be prefaced with `this.`

```C#
// bad
this._capacity = 0;

// good
_capacity = 0;
```

### Git branch naming

When naming git branches, include slash `/` for hierarchical (directory) grouping.

Bad : `calculator-multiplication-fix`

Good : `fix/calculator-multiplication`

/// Represents a parsed binding expression
class BindingExpression {
  final ExpressionType type;
  final String path;
  final String? operator;
  final BindingExpression? left;
  final BindingExpression? right;
  final BindingExpression? trueValue;
  final BindingExpression? falseValue;
  final String? transform;
  final dynamic value;

  /// Whether this expression has an explicit value (distinguishes null literal from no value)
  final bool hasValue;
  final String? methodName;
  final List<BindingExpression>? arguments;

  /// Lambda parameter name (e.g., 'item' in `item => item.price > 100`)
  final String? parameterName;

  /// Second lambda parameter, for the accumulator form:
  /// `reduce(items, (acc, i) => acc + i.price * i.qty, 0)`. Null for the
  /// single-parameter lambdas `filter`/`map` take.
  final String? parameterName2;

  /// The original expression string before parsing, useful for debugging
  /// and logging purposes. Only set on the root expression returned by
  /// [parse]; sub-expressions will have this as `null`.
  final String? source;

  BindingExpression({
    required this.type,
    required this.path,
    this.operator,
    this.left,
    this.right,
    this.trueValue,
    this.falseValue,
    this.transform,
    this.value,
    this.hasValue = false,
    this.methodName,
    this.arguments,
    this.parameterName,
    this.parameterName2,
    this.source,
  });

  /// Parse a binding expression string.
  ///
  /// The returned root expression has [source] set to the original
  /// input string for debugging and logging purposes.
  static BindingExpression parse(String expression) {
    final result = _parse(expression.trim());
    // Attach the original source to the root expression only
    return BindingExpression(
      type: result.type,
      path: result.path,
      operator: result.operator,
      left: result.left,
      right: result.right,
      trueValue: result.trueValue,
      falseValue: result.falseValue,
      transform: result.transform,
      value: result.value,
      hasValue: result.hasValue,
      methodName: result.methodName,
      arguments: result.arguments,
      parameterName: result.parameterName,
      parameterName2: result.parameterName2,
      source: expression,
    );
  }

  /// Internal recursive parser (does not set [source]).
  static BindingExpression _parse(String expression) {
    // Remove whitespace
    expression = expression.trim();

    // Check for transform (single | that is not part of ||)
    String? transform;
    String baseExpr = expression;

    final pipeIndex = expression.indexOf('|');
    if (pipeIndex != -1) {
      // Make sure it's not part of ||
      final isLogicalOr = (pipeIndex > 0 && expression[pipeIndex - 1] == '|') ||
          (pipeIndex < expression.length - 1 &&
              expression[pipeIndex + 1] == '|');
      if (!isLogicalOr) {
        baseExpr = expression.substring(0, pipeIndex).trim();
        transform = expression.substring(pipeIndex + 1).trim();
      }
    }

    // Remove outer parentheses if they wrap the entire expression.
    //
    // Repeated rather than once: `((a + b))` is what a generated document
    // produces when it parenthesises a sub-expression that was already
    // parenthesised, and stripping only the outer pair left `(a + b)` as the
    // *path* of a simple expression, which resolves to null.
    while (baseExpr.startsWith('(') && baseExpr.endsWith(')')) {
      // Check if these parentheses are balanced and wrap the entire expression
      int depth = 0;
      bool wrapsEntireExpression = true;
      for (int i = 0; i < baseExpr.length - 1; i++) {
        if (baseExpr[i] == '(') {
          depth++;
        } else if (baseExpr[i] == ')') {
          depth--;
        }
        if (depth == 0 && i < baseExpr.length - 2) {
          wrapsEntireExpression = false;
          break;
        }
      }
      if (!wrapsEntireExpression) break;
      baseExpr = baseExpr.substring(1, baseExpr.length - 1).trim();
    }

    // Check for ternary operator
    final questionIndex = baseExpr.indexOf('?');
    if (questionIndex != -1) {
      // Find matching colon for this question mark (handle nested ternaries, parentheses, and strings)
      int colonIndex = -1;
      int depth = 0;
      int parenDepth = 0;
      bool inString = false;
      String? stringDelimiter;

      for (int i = questionIndex + 1; i < baseExpr.length; i++) {
        final char = baseExpr[i];

        // Handle string delimiters
        if ((char == '"' || char == "'") &&
            (i == 0 || baseExpr[i - 1] != '\\')) {
          if (!inString) {
            inString = true;
            stringDelimiter = char;
          } else if (char == stringDelimiter) {
            inString = false;
            stringDelimiter = null;
          }
        }

        // Skip characters inside strings
        if (inString) continue;

        if (char == '(') {
          parenDepth++;
        } else if (char == ')') {
          parenDepth--;
        } else if (parenDepth == 0) {
          if (char == '?') {
            depth++;
          } else if (char == ':') {
            if (depth == 0) {
              colonIndex = i;
              break;
            }
            depth--;
          }
        }
      }

      if (colonIndex != -1) {
        final condition = baseExpr.substring(0, questionIndex).trim();
        final trueVal =
            baseExpr.substring(questionIndex + 1, colonIndex).trim();
        final falseVal = baseExpr.substring(colonIndex + 1).trim();

        return BindingExpression(
          type: ExpressionType.conditional,
          path: '',
          left: _parse(condition),
          trueValue: _parse(trueVal), // Parse both values recursively
          falseValue:
              _parse(falseVal), // Parse recursively to handle nested expressions
          transform: transform,
        );
      }
    }

    // Find operators respecting parentheses and precedence
    // First, find the operator with lowest precedence outside parentheses
    int? lowestPrecedenceOpIndex;
    String? lowestPrecedenceOp;
    int lowestPrecedence = 999;

    // Map of operator precedence (lower number = lower precedence)
    final precedenceMap = {
      '??': 0, // Null coalescing has lowest precedence
      '||': 1,
      '&&': 2,
      '==': 3, '!=': 3,
      '>': 4, '<': 4, '>=': 4, '<=': 4,
      '+': 5, '-': 5,
      '*': 6, '/': 6, '%': 6,
    };

    // Scan for operators outside parentheses and strings
    int parenDepth = 0;
    bool inString = false;
    String? stringDelimiter;

    for (int i = 0; i < baseExpr.length; i++) {
      final char = baseExpr[i];

      // Handle string delimiters
      if ((char == '"' || char == "'") && (i == 0 || baseExpr[i - 1] != '\\')) {
        if (!inString) {
          inString = true;
          stringDelimiter = char;
        } else if (char == stringDelimiter) {
          inString = false;
          stringDelimiter = null;
        }
      }

      // Skip characters inside strings
      if (inString) continue;

      if (char == '(') {
        parenDepth++;
      } else if (char == ')') {
        parenDepth--;
      } else if (parenDepth == 0) {
        // Check for two-character operators first to ensure multi-char
        // operators (<=, >=, ==, !=, &&, ||, ??) are matched before
        // their single-char prefixes (<, >, !, &, |, ?)
        if (i < baseExpr.length - 1) {
          final twoChar = baseExpr.substring(i, i + 2);
          if (precedenceMap.containsKey(twoChar)) {
            final precedence = precedenceMap[twoChar]!;
            if (precedence <= lowestPrecedence) {
              // Use <= for left-to-right associativity at same precedence
              lowestPrecedence = precedence;
              lowestPrecedenceOp = twoChar;
              lowestPrecedenceOpIndex = i;
            }
            i++; // Skip next character since we consumed two chars
            continue;
          }
        }

        // Check for single-character operators
        final oneChar = baseExpr[i];
        if (precedenceMap.containsKey(oneChar)) {
          final precedence = precedenceMap[oneChar]!;
          // `-` and `+` are also the sign of a literal. A sign has nothing on
          // its left to be a binary operator OF, so splitting there produced an
          // empty left operand: `-1.57 + (value / max) * 6.28` (a gauge
          // needle) split at index 0 and answered with the right-hand term
          // alone — a needle drawn at the wrong angle, reported by nothing.
          if (_isSignPosition(baseExpr, i)) {
            continue;
          }
          if (precedence <= lowestPrecedence) {
            // Use <= for left-to-right associativity at same precedence
            lowestPrecedence = precedence;
            lowestPrecedenceOp = oneChar;
            lowestPrecedenceOpIndex = i;
          }
        }
      }
    }

    // If we found an operator, split and parse recursively
    if (lowestPrecedenceOpIndex != null && lowestPrecedenceOp != null) {
      final left = baseExpr.substring(0, lowestPrecedenceOpIndex).trim();
      final right = baseExpr
          .substring(lowestPrecedenceOpIndex + lowestPrecedenceOp.length)
          .trim();

      // Determine expression type based on operator
      ExpressionType exprType;
      if (lowestPrecedenceOp == '??') {
        exprType = ExpressionType.nullCoalescing;
      } else if (lowestPrecedenceOp == '||' || lowestPrecedenceOp == '&&') {
        exprType = ExpressionType.logical;
      } else if (['+', '-', '*', '/', '%'].contains(lowestPrecedenceOp)) {
        exprType = ExpressionType.arithmetic;
      } else {
        exprType = ExpressionType.comparison;
      }

      return BindingExpression(
        type: exprType,
        path: '',
        operator: lowestPrecedenceOp,
        left: _parse(left),
        right: _parse(right),
        transform: transform,
      );
    }

    // Check for unary logical operators (highest precedence)
    if (baseExpr.startsWith('!')) {
      final operand = baseExpr.substring(1).trim();
      return BindingExpression(
        type: ExpressionType.logical,
        path: '',
        operator: '!',
        left: _parse(operand),
        transform: transform,
      );
    }

    // A call's RESULT can be the receiver: `filter(items, 'ok').length`.
    // `rows.length` resolves (the path walk answers it), the same reading of
    // the same list through a call did not, and the difference is invisible —
    // it renders as an empty string. Two consumers wrote the "N of M" form and
    // both read a blank. The method form is equivalent to the
    // function form; this makes the receiver an expression rather than only a
    // path.
    final tailMatch =
        RegExp(r'^(.*\))\.([A-Za-z_]\w*)(?:\((.*)\))?$').firstMatch(baseExpr);
    if (tailMatch != null && _hasBalancedCall(tailMatch.group(1)!)) {
      final rawArgs = tailMatch.group(3);
      return BindingExpression(
        type: ExpressionType.methodCall,
        path: '',
        left: _parse(tailMatch.group(1)!),
        methodName: tailMatch.group(2),
        arguments: rawArgs == null ? null : _parseArguments(rawArgs),
        transform: transform,
      );
    }

    // Check for function or method calls
    final callMatch = RegExp(r'^([\w\.]+)\((.*)\)$').firstMatch(baseExpr);
    if (callMatch != null) {
      final fullPath = callMatch.group(1)!;
      final argsString = callMatch.group(2)!;

      // Parse arguments
      final args = _parseArguments(argsString);

      // Check if it's a method call (has a dot before the method name)
      final lastDotIndex = fullPath.lastIndexOf('.');
      if (lastDotIndex > 0) {
        // Method call
        final objectPath = fullPath.substring(0, lastDotIndex);
        final methodName = fullPath.substring(lastDotIndex + 1);

        return BindingExpression(
          type: ExpressionType.methodCall,
          path: objectPath,
          methodName: methodName,
          arguments: args,
          transform: transform,
        );
      } else {
        // Function call
        return BindingExpression(
          type: ExpressionType.functionCall,
          path: '',
          methodName: fullPath,
          arguments: args,
          transform: transform,
        );
      }
    }

    // Check for unary minus/plus operators
    if (baseExpr.startsWith('-') || baseExpr.startsWith('+')) {
      final rest = baseExpr.substring(1).trim();
      // Only treat as unary if the rest is not empty and starts with a valid token
      if (rest.isNotEmpty && !rest.startsWith('-') && !rest.startsWith('+')) {
        final numLiteral = num.tryParse(baseExpr);
        if (numLiteral != null) {
          // It is a negative/positive number literal
          return BindingExpression(
            type: ExpressionType.simple,
            path: '',
            value: numLiteral,
            hasValue: true,
            transform: transform,
          );
        }
        // Unary operator on an expression: treat as arithmetic with 0
        final operand = _parse(rest);
        return BindingExpression(
          type: ExpressionType.arithmetic,
          path: '',
          operator: baseExpr[0] == '-' ? '-' : '+',
          left: BindingExpression(
            type: ExpressionType.simple,
            path: '',
            value: 0,
            hasValue: true,
          ),
          right: operand,
          transform: transform,
        );
      }
    }

    // Check for string literal
    if ((baseExpr.startsWith("'") && baseExpr.endsWith("'")) ||
        (baseExpr.startsWith('"') && baseExpr.endsWith('"'))) {
      return BindingExpression(
        type: ExpressionType.simple,
        path: '',
        value: baseExpr.substring(1, baseExpr.length - 1),
        hasValue: true,
        transform: transform,
      );
    }

    // Check for number literal
    final num? number = num.tryParse(baseExpr);
    if (number != null) {
      return BindingExpression(
        type: ExpressionType.simple,
        path: '',
        value: number,
        hasValue: true,
        transform: transform,
      );
    }

    // Check for boolean literal
    if (baseExpr == 'true' || baseExpr == 'false') {
      return BindingExpression(
        type: ExpressionType.simple,
        path: '',
        value: baseExpr == 'true',
        hasValue: true,
        transform: transform,
      );
    }

    // Check for null literal
    if (baseExpr == 'null') {
      return BindingExpression(
        type: ExpressionType.simple,
        path: '',
        value: null,
        hasValue: true,
        transform: transform,
      );
    }

    // Check for optional chaining (?.) - convert to a safe path access
    if (baseExpr.contains('?.')) {
      return BindingExpression(
        type: ExpressionType.optionalChaining,
        path: baseExpr.replaceAll('?.', '.'),
        transform: transform,
      );
    }

    // Check for index access (e.g., items[0], data['key'])
    final indexMatch = RegExp(r'^([\w\.]+)\[(.+)\]$').firstMatch(baseExpr);
    if (indexMatch != null) {
      final objectPath = indexMatch.group(1)!;
      final indexExpr = indexMatch.group(2)!;
      return BindingExpression(
        type: ExpressionType.indexAccess,
        path: objectPath,
        left: _parse(indexExpr),
        transform: transform,
      );
    }

    // Simple path expression
    return BindingExpression(
      type: ExpressionType.simple,
      path: baseExpr,
      transform: transform,
    );
  }

  /// Whether [expr] is itself a complete call — `name(...)` with its
  /// parentheses balanced — so a trailing `.prop` belongs to its result rather
  /// than to a path that happens to contain brackets.
  static bool _hasBalancedCall(String expr) {
    if (!RegExp(r'^[\w\.]+\(').hasMatch(expr) || !expr.endsWith(')')) {
      return false;
    }
    var depth = 0;
    String? quote;
    for (var i = 0; i < expr.length; i++) {
      final char = expr[i];
      if (quote != null) {
        if (char == quote && (i == 0 || expr[i - 1] != '\\')) quote = null;
        continue;
      }
      if (char == '"' || char == "'") {
        quote = char;
      } else if (char == '(') {
        depth++;
      } else if (char == ')') {
        depth--;
        if (depth == 0 && i != expr.length - 1) {
          // A call that closes before the end is still ONE receiver when what
          // follows is another link in the chain: `filter(rows, 'done')` here
          // is followed by `.map('name')`. Rejecting it outright allowed only
          // a single hop, so `filter(…).map(…).join(…)` fell through to a
          // path lookup and resolved to null — a blank where a joined list
          // belonged, with nothing said. Anything OTHER than a `.` after the
          // close means two terms with an operator between them, which is not
          // a receiver.
          if (i + 1 >= expr.length || expr[i + 1] != '.') return false;
        }
      }
    }
    return depth == 0;
  }

  /// Whether the `+`/`-` at [index] is a SIGN rather than a binary operator:
  /// nothing precedes it, or what precedes it is another operator or an open
  /// paren/comma, which cannot be a left operand.
  static bool _isSignPosition(String expr, int index) {
    if (expr[index] != '-' && expr[index] != '+') return false;
    var i = index - 1;
    while (i >= 0 && expr[i] == ' ') {
      i--;
    }
    if (i < 0) return true;
    return '+-*/%<>=!&|?(,'.contains(expr[i]);
  }

  /// Whether [expr] has a binary operator at its top level — the same scan the
  /// parser uses, asked as a question. Arguments need it: the grammar
  /// makes an argument an `Expression`, so `round(price * quantity, 2)` is
  /// legal, and treating it as a path made it a lookup for a variable *named*
  /// `price * quantity`.
  static bool _hasTopLevelBinaryOperator(String expr) {
    const operators = '+-*/%<>=!&|?';
    var depth = 0;
    String? quote;
    for (var i = 0; i < expr.length; i++) {
      final char = expr[i];
      if (quote != null) {
        if (char == quote && (i == 0 || expr[i - 1] != '\\')) quote = null;
        continue;
      }
      if (char == '"' || char == "'") {
        quote = char;
      } else if (char == '(' || char == '[') {
        depth++;
      } else if (char == ')' || char == ']') {
        depth--;
      } else if (depth == 0 &&
          operators.contains(char) &&
          !_isSignPosition(expr, i)) {
        return true;
      }
    }
    return false;
  }

  /// Parse function/method arguments
  static List<BindingExpression> _parseArguments(String argsString) {
    if (argsString.trim().isEmpty) return [];

    final args = <BindingExpression>[];
    var depth = 0;
    var currentArg = '';
    String? quote;

    // Split by comma, respecting nested parentheses *and* quoted strings. A
    // comma inside a quoted argument used to end the argument: the documented
    // example `format(price, '#,##0.00')` arrived as three arguments, so the
    // pattern lost its grouping and its decimals and the number came back
    // rounded to an integer. `split(text, ',')` had the same shape.
    for (var i = 0; i < argsString.length; i++) {
      final char = argsString[i];

      if (quote != null) {
        currentArg += char;
        if (char == quote) quote = null;
        continue;
      }

      if (char == '"' || char == "'") {
        quote = char;
      } else if (char == '(') {
        depth++;
      } else if (char == ')') {
        depth--;
      } else if (char == ',' && depth == 0) {
        // Found argument separator at top level
        if (currentArg.trim().isNotEmpty) {
          args.add(_parseValue(currentArg.trim()));
        }
        currentArg = '';
        continue;
      }

      currentArg += char;
    }

    // Add the last argument
    if (currentArg.trim().isNotEmpty) {
      args.add(_parseValue(currentArg.trim()));
    }

    return args;
  }

  /// Parse a value (could be a literal or another expression)
  static BindingExpression _parseValue(String value) {
    value = value.trim();

    // Check for lambda expression: param => body, or (acc, item) => body
    final arrowIndex = value.indexOf('=>');
    if (arrowIndex > 0) {
      final paramPart = value.substring(0, arrowIndex).trim();
      final bodyPart = value.substring(arrowIndex + 2).trim();
      // Validate parameter name is a simple identifier
      if (RegExp(r'^[a-zA-Z_]\w*$').hasMatch(paramPart) && bodyPart.isNotEmpty) {
        return BindingExpression(
          type: ExpressionType.lambda,
          path: '',
          parameterName: paramPart,
          left: _parse(bodyPart),
        );
      }
      // `(acc, item) => body` — the accumulator form written for
      // `reduce`. Only the one-parameter spelling parsed, so the spec's own
      // example fell through to a path lookup and reduce answered with its
      // initial value: a total of 0 that reads like an empty cart.
      // `(r) => body` — the same lambda, parenthesised. Only the bare `r =>`
      // spelling parsed, so this fell through to the operator branch and came
      // back as a value; `filter` then read that value as a property NAME and
      // answered with an empty list. An author who writes their predicate the
      // way every other language writes it got no rows and no error.
      final single =
          RegExp(r'^\(\s*([a-zA-Z_]\w*)\s*\)$').firstMatch(paramPart);
      if (single != null && bodyPart.isNotEmpty) {
        return BindingExpression(
          type: ExpressionType.lambda,
          path: '',
          parameterName: single.group(1),
          left: _parse(bodyPart),
        );
      }
      final pair = RegExp(r'^\(\s*([a-zA-Z_]\w*)\s*,\s*([a-zA-Z_]\w*)\s*\)$')
          .firstMatch(paramPart);
      if (pair != null && bodyPart.isNotEmpty) {
        return BindingExpression(
          type: ExpressionType.lambda,
          path: '',
          parameterName: pair.group(1),
          parameterName2: pair.group(2),
          left: _parse(bodyPart),
        );
      }
    }

    // An argument is an Expression, so it may be an operation — the
    // documented example is `round(price * quantity, 2)`. This must be
    // asked BEFORE the unary branch below: `-1.57 + 0.5` starts with a sign,
    // and reading it as "unary minus applied to the rest" makes the sign
    // swallow the whole expression — `-(1.57 + 0.5)`, so a gauge angle
    // came back with the wrong sign the moment an author wrapped it in
    // `round(…)` to fix the decimals. `_parse` splits on the operator first
    // and treats the leading sign as the sign of its own term.
    if (_hasTopLevelBinaryOperator(value)) {
      return _parse(value);
    }

    // Check for unary logical operators
    if (value.startsWith('!')) {
      final operand = value.substring(1).trim();
      return BindingExpression(
        type: ExpressionType.logical,
        path: '',
        operator: '!',
        left: _parseValue(operand),
      );
    }

    // Check for unary minus/plus on expressions
    if ((value.startsWith('-') || value.startsWith('+')) && value.length > 1) {
      final numLiteral = num.tryParse(value);
      if (numLiteral != null) {
        return BindingExpression(
          type: ExpressionType.simple,
          path: '',
          value: numLiteral,
          hasValue: true,
        );
      }
      // Unary on a non-literal expression
      final rest = value.substring(1).trim();
      return BindingExpression(
        type: ExpressionType.arithmetic,
        path: '',
        operator: value[0] == '-' ? '-' : '+',
        left: BindingExpression(
          type: ExpressionType.simple,
          path: '',
          value: 0,
          hasValue: true,
        ),
        right: _parseValue(rest),
      );
    }

    // String literal
    if ((value.startsWith("'") && value.endsWith("'")) ||
        (value.startsWith('"') && value.endsWith('"'))) {
      return BindingExpression(
        type: ExpressionType.simple,
        path: '',
        value: value.substring(1, value.length - 1),
        hasValue: true,
      );
    }

    // Number literal
    final num? number = num.tryParse(value);
    if (number != null) {
      return BindingExpression(
        type: ExpressionType.simple,
        path: '',
        value: number,
        hasValue: true,
      );
    }

    // Boolean literal
    if (value == 'true' || value == 'false') {
      return BindingExpression(
        type: ExpressionType.simple,
        path: '',
        value: value == 'true',
        hasValue: true,
      );
    }

    // Null literal
    if (value == 'null') {
      return BindingExpression(
        type: ExpressionType.simple,
        path: '',
        value: null,
        hasValue: true,
      );
    }

    // A nested call is an expression, not a path. Falling through to the path
    // branch turned `length(filter(rows, …))` into a lookup for a variable
    // *named* `filter(rows, …)`, which resolves to null — so the composition
    // the documentation shows (`length(filter(items, 'completed'))`)
    // answered 0 for every input.
    if (RegExp(r'^[\w\.]+\(.*\)$').hasMatch(value)) {
      return _parse(value);
    }

    // Otherwise, treat as a path expression
    return BindingExpression(
      type: ExpressionType.simple,
      path: value,
    );
  }
}

/// Types of binding expressions
enum ExpressionType {
  simple, // Direct path: {{variable}}
  conditional, // Ternary: {{condition ? true : false}}
  arithmetic, // Math: {{a + b}}
  comparison, // Compare: {{a > b}}
  logical, // Logic: {{a && b}}, {{a || b}}, {{!a}}
  nullCoalescing, // Null coalescing: {{a ?? b}}
  methodCall, // Method call: {{value.method(args)}}
  functionCall, // Function call: {{func(args)}}
  optionalChaining, // Optional chaining: {{a?.b?.c}}
  indexAccess, // Index access: {{items[0]}}, {{data['key']}}
  lambda, // Lambda: item => item.price > 100
}

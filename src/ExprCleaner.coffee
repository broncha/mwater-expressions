_ = require 'lodash'
ExprUtils = require './ExprUtils'

# Cleans expressions. Cleaning means nulling invalid (not just incomplete) expressions if they cannot be auto-fixed.
module.exports = class ExprCleaner
  constructor: (schema) ->
    @schema = schema
    @exprUtils = new ExprUtils(schema)

  # Clean an expression, returning null if completely invalid, otherwise removing
  # invalid parts. Attempts to correct invalid types by wrapping in other expressions.
  # e.g. if an enum is chosen when a boolean is required, it will be wrapped in "= any" op
  # options are:
  #   table: optional current table. expression must be related to this table or will be stripped
  #   types: optional types to limit to
  #   enumValueIds: ids of enum values that are valid if type is enum
  #   idTable: table that type of id must be from
  cleanExpr: (expr, options={}) ->
    if not expr
      return null

    # Allow {} placeholder
    if _.isEmpty(expr)
      return expr

    # Handle upgrades from old version
    if expr.type == "comparison"
      return @cleanComparisonExpr(expr, options)
    if expr.type == "logical"
      return @cleanLogicalExpr(expr, options)
    if expr.type == "count"
      return @cleanCountExpr(expr, options)
    if expr.type == "literal" and expr.valueType == "enum[]"
      expr = { type: "literal", valueType: "enumset", value: expr.value }

    # Strip if wrong table 
    if options.table and expr.type != "literal" and expr.table != options.table
      return null

    # Strip if no table
    if not expr.table and expr.type != "literal" 
      return null

    # Strip if non-existent table
    if expr.table and not @schema.getTable(expr.table)
      return null

    # Get type
    type = @exprUtils.getExprType(expr)

    # Strip if wrong type
    if type and options.types and type not in options.types
      # case statements should be preserved as they are a variable type and they will have their then clauses cleaned
      if expr.type != "case"
        return null

    switch expr.type
      when "field"
        return @cleanFieldExpr(expr, options)
      when "scalar"
        return @cleanScalarExpr(expr, options)
      when "op"
        return @cleanOpExpr(expr, options)
      when "literal"
        return @cleanLiteralExpr(expr, options)
      when "case"
        return @cleanCaseExpr(expr, options)
      when "id"
        return @cleanIdExpr(expr, options)
      when "score"
        return @cleanScoreExpr(expr, options)
      else
        throw new Error("Unknown expression type #{expr.type}")

  # Removes references to non-existent tables
  cleanFieldExpr: (expr, options) ->
    # Empty expression
    if not expr.column or not expr.table
      return null

    # Missing table
    if not @schema.getTable(expr.table)
      return null

    # Missing column
    column = @schema.getColumn(expr.table, expr.column)
    if not column
      return null

    # Invalid enums
    if options.enumValueIds and column.type == "enum"
      if _.difference(_.pluck(column.enumValues, "id"), options.enumValueIds).length > 0
        return null

    return expr

  cleanOpExpr: (expr, options) ->
    switch expr.op
      when "and", "or"
        expr = _.extend({}, expr, exprs: _.map(expr.exprs, (e) => @cleanExpr(e, types: ["boolean"], table: expr.table)))

        # Simplify
        if expr.exprs.length == 1
          return expr.exprs[0]
        if expr.exprs.length == 0
          return null

        return expr
      when "+", "*"
        expr = _.extend({}, expr, exprs: _.map(expr.exprs, (e) => @cleanExpr(e, types: ["number"], table: expr.table)))

        # Simplify
        if expr.exprs.length == 1
          return expr.exprs[0]
        if expr.exprs.length == 0
          return null

        return expr
      else 
        # Get opItem
        opItems = @exprUtils.findMatchingOpItems(op: expr.op, lhsExpr: expr.exprs[0], resultTypes: options.types)

        # Need LHS for a normal op that is not a prefix. If it is a prefix op, allow the op to stand alone without params
        if not expr.exprs[0] and not opItems[0]?.prefix
          return null

        # If ambiguous, just clean subexprs and return
        if opItems.length > 1
          return _.extend({}, expr, { exprs: _.map(expr.exprs, (e, i) =>
            @cleanExpr(e, table: expr.table)
          )})

        # If not found, default opItem
        if not opItems[0]
          opItem = @exprUtils.findMatchingOpItems(lhsExpr: expr.exprs[0], resultTypes: options.types)[0]
          if not opItem
            return null

          expr = { type: "op", table: expr.table, op: opItem.op, exprs: [expr.exprs[0] or null] }  
        else
          opItem = opItems[0]

        # Pad or trim number of expressions
        while expr.exprs.length < opItem.exprTypes.length
          exprs = expr.exprs.slice()
          exprs.push(null)
          expr = _.extend({}, expr, { exprs: exprs })

        if expr.exprs.length > opItem.exprTypes.length
          expr = _.extend({}, expr, { exprs: _.take(expr.exprs, opItem.exprTypes.length) })          

        # Clean all sub expressions
        if expr.exprs[0]
          enumValues = @exprUtils.getExprEnumValues(expr.exprs[0])
          if enumValues
            enumValueIds = _.pluck(enumValues, "id")

        expr = _.extend({}, expr, { exprs: _.map(expr.exprs, (e, i) =>
          @cleanExpr(e, table: expr.table, types: (if opItem.exprTypes[i] then [opItem.exprTypes[i]]), enumValueIds: enumValueIds, idTable: @exprUtils.getExprIdTable(expr.exprs[0]))
          )})

        return expr

  # Determines if an set of joins are valid
  areJoinsValid: (table, joins) ->
    t = table
    for j in joins
      joinCol = @schema.getColumn(t, j)
      if not joinCol 
        return false

      t = joinCol.join.toTable

    return true

  # Strips/defaults invalid aggr and where of a scalar expression
  cleanScalarExpr: (expr, options) ->
    if expr.joins.length == 0
      return @cleanExpr(expr.expr, options)

    # Fix legacy entity joins (accidentally had entities.<tablename>. prepended)
    joins = _.map(expr.joins, (j) =>
      if j.match(/^entities\.[a-z_0-9]+\./)
        return j.split(".")[2]
      return j
      )
    expr = _.extend({}, expr, joins: joins)

    if not @exprUtils.areJoinsValid(expr.table, expr.joins)
      return null

    # If invalid aggr or no inner expression, remove aggr
    if expr.aggr and (not @exprUtils.isMultipleJoins(expr.table, expr.joins) or not expr.expr)
      expr = _.omit(expr, "aggr")

    # If aggr is required and there is one possible, use it
    if expr.expr and @exprUtils.isMultipleJoins(expr.table, expr.joins) and expr.aggr not in _.pluck(@exprUtils.getAggrs(expr.expr), "id")
      aggrs = @exprUtils.getAggrs(expr.expr)
      if aggrs.length > 0
        expr = _.extend({}, expr, { aggr: aggrs[0].id })

    # Clean where
    if expr.where
      expr.where = @cleanExpr(expr.where)

    # Clean inner expr
    innerTable = @exprUtils.followJoins(expr.table, expr.joins)

    # Get inner expression type (must match unless is count which can count anything)
    if expr.expr
      innerTypes = if expr.aggr != "count" then options.types
      expr = _.extend({}, expr, { 
        expr: @cleanExpr(expr.expr, _.extend({}, options, { table: innerTable, types: innerTypes }))
      })    

    return expr

  cleanLiteralExpr: (expr, options) ->
    # Convert old types
    if expr.valueType in ['decimal', 'integer']
      expr = _.extend({}, expr, { valueType: "number"})

    # TODO strip if no value?

    # Remove if enum type is wrong
    if expr.valueType == "enum" and options.enumValueIds and expr.value and expr.value not in options.enumValueIds
      return null

    # Remove invalid enum types
    if expr.valueType == "enumset" and options.enumValueIds and expr.value
      expr = _.extend({}, expr, value: _.intersection(options.enumValueIds, expr.value))

    # Null if wrong table
    if expr.valueType == "id" and options.idTable and expr.idTable != options.idTable
      return null

    return expr

  cleanCaseExpr: (expr, options) ->
    # Simplify if no cases
    if expr.cases.length == 0
      return expr.else or null

    # Clean whens as boolean
    expr = _.extend({}, expr, 
      cases: _.map(expr.cases, (c) => 
        _.extend({}, c, {
          when: @cleanExpr(c.when, types: ["boolean"], table: expr.table)
          then: @cleanExpr(c.then, options)
        })
      )
      else: @cleanExpr(expr.else, options)
    )

    return expr

  cleanIdExpr: (expr, options) ->
    # Null if wrong table
    if options.idTable and expr.table != options.idTable
      return null
    return expr

  cleanScoreExpr: (expr, options) ->
    # Clean input
    expr = _.extend({}, expr, input: @cleanExpr(expr.input, { types: ['enum', 'enumset' ] }))

    # Remove scores if no input
    if not expr.input
      expr = _.extend({}, expr, scores: {})

    # Clean score values
    expr = _.extend({}, expr, scores: _.mapValues(expr.scores, (scoreExpr) => @cleanExpr(scoreExpr, { table: expr.table, types: ['number']})))

    # Remove unknown enum values 
    if expr.input
      enumValues = @exprUtils.getExprEnumValues(expr.input)
      expr = _.extend({}, expr, scores: _.pick(expr.scores, (value, key) =>
        return _.findWhere(enumValues, id: key) and value?
      ))

    return expr

  cleanComparisonExpr: (expr, options) =>
    # Upgrade to op
    newExpr = { type: "op", table: expr.table, op: expr.op, exprs: [expr.lhs] }
    if expr.rhs
      newExpr.exprs.push(expr.rhs)

    # Clean sub-expressions to handle legacy literals
    newExpr.exprs = _.map(newExpr.exprs, (e) => @cleanExpr(e))

    # If = true
    if expr.op == "= true"
      newExpr = expr.lhs

    if expr.op == "= false"
      newExpr = { type: "op", op: "not", table: expr.table, exprs: [expr.lhs] }

    if expr.op == "between" and expr.rhs and expr.rhs.type == "literal" and expr.rhs.valueType == "daterange"
      newExpr.exprs = [expr.lhs, { type: "literal", valueType: "date", value: expr.rhs.value[0] }, { type: "literal", valueType: "date", value: expr.rhs.value[1] }]

    if expr.op == "between" and expr.rhs and expr.rhs.type == "literal" and expr.rhs.valueType == "datetimerange"
      # If date, convert datetime to date
      if @exprUtils.getExprType(expr.lhs) == "date"
        newExpr.exprs = [expr.lhs, { type: "literal", valueType: "date", value: expr.rhs.value[0].substr(0, 10) }, { type: "literal", valueType: "date", value: expr.rhs.value[1].substr(0, 10) }]
      else        
        newExpr.exprs = [expr.lhs, { type: "literal", valueType: "datetime", value: expr.rhs.value[0] }, { type: "literal", valueType: "datetime", value: expr.rhs.value[1] }]

    return @cleanExpr(newExpr, options)

  cleanLogicalExpr: (expr, options) =>
    newExpr = { type: "op", op: expr.op, table: expr.table, exprs: expr.exprs }
    return @cleanExpr(newExpr, options)

  cleanCountExpr: (expr, options) =>
    newExpr = { type: "id", table: expr.table }
    return @cleanExpr(newExpr, options)


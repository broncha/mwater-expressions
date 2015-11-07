assert = require('chai').assert
fixtures = require './fixtures'
_ = require 'lodash'

ExprCompiler = require '../src/ExprCompiler'

describe "ExprCompiler", ->
  before ->
    @ec = new ExprCompiler(fixtures.simpleSchema())

  it "compiles field", ->
    jql = @ec.compileExpr(expr: { type: "field", table: "t1", column: "number" }, tableAlias: "T1")
    assert _.isEqual jql, {
      type: "field"
      tableAlias: "T1"
      column: "number"
    }

  it "compiles scalar with no joins, simplifying", ->
    expr = { type: "scalar", table: "t1", expr: { type: "field", table: "t1", column: "number" }, joins: [] }
    jql = @ec.compileExpr(expr: expr, tableAlias: "T1")

    assert _.isEqual(jql, { type: "field", tableAlias: "T1", column: "number" }), JSON.stringify(jql, null, 2)

  it "compiles scalar with one join", ->
    expr = { type: "scalar", table: "t1", expr: { type: "field", table: "t2", column: "number" }, joins: ["1-2"] }
    jql = @ec.compileExpr(expr: expr, tableAlias: "T1")

    assert _.isEqual(jql, {
      type: "scalar"
      expr: { type: "field", tableAlias: "j1", column: "number" }
      from: { type: "table", table: "t2", alias: "j1" }
      where: { type: "op", op: "=", exprs: [
        { type: "field", tableAlias: "j1", column: "t1" }
        { type: "field", tableAlias: "T1", column: "primary" }
        ]}
    }), JSON.stringify(jql, null, 2)

  it "compiles scalar with one join and sql aggr", ->
    expr = { type: "scalar", table: "t1", expr: { type: "field", table: "t2", column: "number" }, joins: ["1-2"], aggr: "count" }
    jql = @ec.compileExpr(expr: expr, tableAlias: "T1")

    assert _.isEqual(jql, {
      type: "scalar"
      expr: { type: "op", op: "count", exprs: [{ type: "field", tableAlias: "j1", column: "number" }] }
      from: { type: "table", table: "t2", alias: "j1" }
      where: { type: "op", op: "=", exprs: [
        { type: "field", tableAlias: "j1", column: "t1" }
        { type: "field", tableAlias: "T1", column: "primary" }
        ]}
    }), JSON.stringify(jql, null, 2)

  it "compiles scalar with one join and count(*) aggr", ->
    expr = { type: "scalar", table: "t1", expr: { type: "count", table: "t2" }, joins: ["1-2"], aggr: "count" }
    jql = @ec.compileExpr(expr: expr, tableAlias: "T1")

    assert _.isEqual(jql, {
      type: "scalar"
      expr: { type: "op", op: "count", exprs: [] }
      from: { type: "table", table: "t2", alias: "j1" }
      where: { type: "op", op: "=", exprs: [
        { type: "field", tableAlias: "j1", column: "t1" }
        { type: "field", tableAlias: "T1", column: "primary" }
        ]}
    }), JSON.stringify(jql, null, 2)


  it "compiles scalar with one join and last aggr", ->
    expr = { type: "scalar", table: "t1", expr: { type: "field", table: "t2", column: "number" }, joins: ["1-2"], aggr: "last" }
    jql = @ec.compileExpr(expr: expr, tableAlias: "T1")

    refJql = {
      type: "scalar"
      expr: { type: "field", tableAlias: "j1", column: "number" }
      from: { type: "table", table: "t2", alias: "j1" }
      where: { type: "op", op: "=", exprs: [
        { type: "field", tableAlias: "j1", column: "t1" }
        { type: "field", tableAlias: "T1", column: "primary" }
        ]}
      orderBy: [{ expr: { type: "field", tableAlias: "j1", column: "number" }, direction: "desc" }]
      limit: 1
    }

    assert _.isEqual(jql, refJql), "\n" + JSON.stringify(jql) + "\n" + JSON.stringify(refJql)

  it "compiles scalar with two joins", -> 
    expr = { type: "scalar", table: "t1", expr: { type: "field", table: "t1", column: "number" }, joins: ["1-2", "2-1"], aggr: "count" }
    jql = @ec.compileExpr(expr: expr, tableAlias: "T1")

    assert _.isEqual(jql, {
      type: "scalar"
      expr: { type: "op", op: "count", exprs: [{ type: "field", tableAlias: "j2", column: "number" }] }
      from: { 
        type: "join" 
        left: { type: "table", table: "t2", alias: "j1" }
        right: { type: "table", table: "t1", alias: "j2" }
        kind: "left"
        on: { type: "op", op: "=", exprs: [
          { type: "field", tableAlias: "j1", column: "t1" }
          { type: "field", tableAlias: "j2", column: "primary" }
          ]}
        } 
      where: { type: "op", op: "=", exprs: [
        { type: "field", tableAlias: "j1", column: "t1" }
        { type: "field", tableAlias: "T1", column: "primary" }
        ]}
    }), JSON.stringify(jql, null, 2)

  it "compiles scalar with one join and where", ->
    where = {
      "type": "logical",
      "op": "and",
      "exprs": [
        {
          "type": "comparison",
          "lhs": {
            "type": "scalar",
            "baseTableId": "t2",
            "expr": {
              "type": "field",
              "table": "t2",
              "column": "number"
            },
            "joins": []
          },
          "op": "=",
          "rhs": {
            "type": "literal",
            "valueType": "number",
            "value": 3
          }
        }
      ]
    }

    expr = { 
      type: "scalar", 
      table: "t1",      
      expr: { type: "field", table: "t2", column: "number" }, 
      joins: ["1-2"], 
      where: where
    }
    jql = @ec.compileExpr(expr: expr, tableAlias: "T1")

    assert _.isEqual(jql, {
      type: "scalar"
      expr: { type: "field", tableAlias: "j1", column: "number" }
      from: { type: "table", table: "t2", alias: "j1" }
      where: {
        type: "op"
        op: "and"
        exprs: [
          { type: "op", op: "=", exprs: [
            { type: "field", tableAlias: "j1", column: "t1" }
            { type: "field", tableAlias: "T1", column: "primary" }
            ]
          }
          {
            type: "op", op: "=", exprs: [
              { type: "field", tableAlias: "j1", column: "number" }
              { type: "literal", value: 3 }
            ]
          }
        ]
      }
    }), JSON.stringify(jql, null, 2)

  it "compiles literals", ->
    assert.deepEqual @ec.compileExpr(expr: { type: "literal", valueType: "text", value: "abc" }), { type: "literal", value: "abc" }
    assert.deepEqual @ec.compileExpr(expr: { type: "literal", valueType: "number", value: 123 }), { type: "literal", value: 123 }
    assert.deepEqual @ec.compileExpr(expr: { type: "literal", valueType: "enum", value: "id1" }), { type: "literal", value: "id1" }
    assert.deepEqual @ec.compileExpr(expr: { type: "literal", valueType: "boolean", value: true }), { type: "literal", value: true }

  describe "comparisons", ->
    it "compiles =", ->
      expr = { 
        type: "comparison"
        op: "="
        lhs: { type: "field", table: "t1", column: "number" }
        rhs: { type: "literal", valueType: "number", value: 3 }
      }

      jql = @ec.compileExpr(expr: expr, tableAlias: "T1")

      assert _.isEqual(jql, {
        type: "op"
        op: "="
        exprs: [
          { type: "field", tableAlias: "T1", column: "number" }
          { type: "literal", value: 3 }
        ]
        }), JSON.stringify(jql, null, 2)

    it "compiles = any", ->
      expr = { 
        type: "comparison", op: "= any", 
        lhs: { type: "field", table: "t1", column: "enum" } 
        rhs: { type: "literal", valueType: "enum[]", value: ["a", "b"] }
      }

      jql = @ec.compileExpr(expr: expr, tableAlias: "T1")

      assert _.isEqual(jql, {
        type: "op"
        op: "="
        modifier: "any"
        exprs: [
          { type: "field", tableAlias: "T1", column: "enum" }
          { type: "literal", value: ["a", "b"] }
        ]
        }), JSON.stringify(jql, null, 2)

   
    it "compiles no rhs as null", ->
      expr = { 
        type: "comparison"
        op: "="
        lhs: { type: "field", table: "t1", column: "number" }
      }

      jql = @ec.compileExpr(expr: expr, tableAlias: "T1")

      assert not jql

    it "compiles daterange", ->
      expr = { 
        type: "comparison"
        op: "between"
        lhs: { type: "field", table: "t1", column: "date" }
        rhs: { type: "literal", valueType: "daterange", value: ["2014-01-01", "2014-12-31"] }
      }

      jql = @ec.compileExpr(expr: expr, tableAlias: "T1")

      assert _.isEqual(jql, {
        type: "op"
        op: "between"
        exprs: [
          { type: "field", tableAlias: "T1", column: "date" }
          { type: "literal", value: "2014-01-01" }
          { type: "literal", value: "2014-12-31" }
        ]
        }), JSON.stringify(jql, null, 2)


  describe "logicals", ->
    it "simplifies logical", ->
      expr1 = { type: "comparison", op: "= false", lhs: { type: "field", table: "t1", column: "boolean" } }

      expr = { type: "logical", op: "and", exprs: [expr1] }

      jql = @ec.compileExpr(expr: expr, tableAlias: "T1")

      assert _.isEqual(jql, 
        {
          type: "op"
          op: "="
          exprs: [
            { type: "field", tableAlias: "T1", column: "boolean" }
            { type: "literal", value: false }
          ]
        }
      ), JSON.stringify(jql, null, 2)

    it "compiles logical", ->
      expr1 = { type: "comparison", op: "=", lhs: { type: "field", table: "t1", column: "number" }, rhs: { type: "literal", valueType: "number", value: 3 } }

      expr2 = { type: "comparison", op: "= false", lhs: { type: "field", table: "t1", column: "boolean" } }

      expr = { type: "logical", op: "and", exprs: [expr1, expr2] }
      jql = @ec.compileExpr(expr: expr, tableAlias: "T1")

      assert _.isEqual(jql, 
        { type: "op", op: "and", exprs: [
          {
            type: "op"
            op: "="
            exprs: [
              { type: "field", tableAlias: "T1", column: "number" }
              { type: "literal", value: 3 }
            ]
          },
          {
            type: "op"
            op: "="
            exprs: [
              { type: "field", tableAlias: "T1", column: "boolean" }
              { type: "literal", value: false }
            ]
          }
        ]}
      ), JSON.stringify(jql, null, 2)

    it "excluded blank condition", ->
      expr1 = { type: "comparison", op: "= true", lhs: { type: "field", table: "t1", column: "number" } }

      expr2 = { type: "comparison", op: "=", lhs: { type: "field", table: "t1", column: "number" } } # No RHS

      expr = { type: "logical", op: "and", exprs: [expr1, expr2] }
      jql = @ec.compileExpr(expr: expr, tableAlias: "T1")

      assert _.isEqual(jql, 
        {
          type: "op"
          op: "="
          exprs: [
            { type: "field", tableAlias: "T1", column: "number" }
            { type: "literal", value: true }
          ]
        }
      ), JSON.stringify(jql, null, 2)

  describe "custom jsonql", ->
    describe "table", ->
      it "substitutes table", ->
        schema = fixtures.simpleSchema()
        tableJsonql = {
          type: "query"
          selects: [
            {
              type: "field"
              tableAlias: "abc"
              column: "number"
            }
          ]
          from: { type: "table", table: "t2", alias: "abc" }
        }

        # Customize t2
        schema.getTable("t2").jsonql = tableJsonql
        
        ec = new ExprCompiler(schema)

        jql = ec.compileExpr(expr: { type: "scalar", table: "t1", joins: ["1-2"], expr: { type: "field", table: "t2", column: "number" } }, tableAlias: "T1")

        from = {
          type: "subquery",
          query: {
            type: "query",
            selects: [
              {
                type: "field",
                tableAlias: "abc",
                column: "number"
              }
            ],
            from: {
              type: "table",
              table: "t2",
              alias: "abc"
            }
          },
          alias: "j1"
        }

        assert _.isEqual(jql.from, from), JSON.stringify(jql, null, 2)

    # describe "join"
    describe "column", ->
      it "substitutes {alias}", ->
        schema = fixtures.simpleSchema()
        columnJsonql = {
          type: "op"
          op: "sum"
          exprs: [
            {
              type: "field"
              tableAlias: "{alias}"  # Should be replaced!
              column: "number"
            }
          ]
        }

        schema = schema.addTable({ id: "t1", contents:[{ id: "custom", name: "Custom", type: "text", jsonql: columnJsonql }]})
        
        ec = new ExprCompiler(schema)

        jql = ec.compileExpr(expr: { type: "field", table: "t1", column: "custom" }, tableAlias: "T1")

        assert _.isEqual jql, {
          type: "op"
          op: "sum"
          exprs: [
            {
              type: "field"
              tableAlias: "T1" # Replaced with table alias
              column: "number"
            }
          ]
        }
import db_sqlite, json
from strutils import parseInt

type
    Tfield = tuple[name: string, kind: string]

    Tindex = tuple[name: string, fields: seq[Tfield]]

    Tmodel* = ref object of RootObj
        id*: int64

    Torm* = ref object
        db: DbConn
        lookup: seq[Tindex]

    Torder* = enum
        Asc = " ASC ", Desc = " DESC "

proc Tinit*[T: Tmodel](self: T): Tindex =
    ## Make an Tindex of the Tmodel which can be used inside by Torm.lookup
    result = (name: $typedesc(self), fields: @[])
    for col, value in self[].fieldPairs:
        result.fields.add((name: col, kind: $typeof(value)))

proc Trow[T: Tmodel](self: T, row: seq[string], index: Tindex): T =
    var json = "{\"id\": " & row[0]
    var i = 1
    for field in index.fields:
        if field.name != "id":
            json &= ", \"" & field.name & "\": " & (if field.kind == "string": escapeJson row[i] else: escapeJsonUnquoted row[i])
            i += 1
    result = to(parseJson(json & "}"), T)

proc fieldInfo(this: Torm, field: Tfield): string =
    if field.name == "id":
        result = "INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL"
    else:
        result = case field.kind:
            of "bool":
                "BOOLEAN NOT NULL DEFAULT false"
            of "int8", "int16", "int32", "int64", "int":
                "INTEGER NOT NULL DEFAULT 0"
            else:
                "TEXT"

proc getIndex(self: Torm, q: string): Tindex =
    for match in self.lookup:
        if q == match.name:
            result = match

proc newTorm*(dbName: string, lookup: seq[Tindex]): Torm =
    let db = open(dbName, "", "", "")
    let orm = Torm(db: db, lookup: lookup)

    for model in lookup:
        var list: seq[string] = @[]
        for row in db.fastRows(sql("PRAGMA table_info(" & model.name & ");")):
            list.add(row[1])
        if list.len > 0:
            # Lets check if new columns have been added
            for field in model.fields:
                if not list.contains(field.name):
                    var statement = "ALTER TABLE \"" & model.name & "\" ADD COLUMN " & field.name & " " & orm.fieldInfo(field) & ";"
                    db.exec(sql(statement))

        else:
            # Lets make a new table
            var statement = "CREATE TABLE IF NOT EXISTS \"" & model.name & "\" ("
            for field in model.fields:
                if statement[^1] != '(': statement &= ", "
                statement &= "\"" & field.name & "\" " & orm.fieldInfo(field)
            statement &= ");"
            db.exec(sql(statement))

    return orm

proc insert[T: Tmodel](self: Torm, model: T): int64 {.discardable.} =
    var statement = "INSERT INTO \"" & $typedesc(model) & "\" ("
    var late = " VALUES ("
    var list: seq[string] = @[]
    for col, value in model[].fieldPairs:
        if col != "id":
            if statement[^1] != '(': statement &= ", "
            statement &= col
            if late[^1] != '(': late &= ", "
            late &= "?"
            list.add($value)
    let prepared = statement & ")" & late & ")"
    model.id = self.db.tryInsertID(sql prepared, list)
    result = model.id

proc update[T: Tmodel](self: Torm, model: T): bool {.discardable.} =
    var statement = "UPDATE \"" & $typedesc(model) & "\" SET "
    var list: seq[string] = @[]
    for col, value in model[].fieldPairs:
        if col != "id":
            if statement[^1] != ' ': statement &= ", "
            statement &= col & " = ?"
            list.add($value)
    list.add($model.id)
    statement &= " WHERE id = ?"
    result = self.db.tryExec(sql statement, list)

proc find[T: Tmodel](self: Torm, model: T, where = (clause: "", values: @[""]), order = (by: "id", way: Torder.Asc), limit = 0, offset = 0, countOnly = false): tuple[count: int, objects: seq[T]] =
    let index = self.getIndex($typedesc(model))
    var select = "id"
    for field in index.fields:
        if field.name != "id": select &= "," & field.name
    if countOnly: select = "COUNT(*) AS total"
    select = "SELECT " & select & " FROM \"" & index.name & "\""
    if where.clause != "":
        select &= " WHERE " & where.clause
    select &= " ORDER BY " & order.by & $order.way
    if not countOnly:
        if limit > 0: select &= " LIMIT " & $limit
        if offset > 0: select &= " OFFSET " & $offset

    for x in self.db.fastRows(sql select, where.values):
        if not countOnly:
            result.objects.add T().Trow(x, index)
            result.count += 1
        else:
            result.count = parseInt x[0]

proc findOne*[T: Tmodel](this: Torm, model: T, id: int64): T =
    let res = this.find(model, where = (clause: "id = ?", values: @[$id]), limit = 1)
    if res.objects.len > 0:
        result = res.objects[0]
    else: result = model

proc findMany*[T: Tmodel](this: Torm, model: T, where = (clause: "", values: @[""]), order = (by: "id", way: Torder.Asc), limit = 0, offset = 0): seq[T] =
    result = this.find(model, where = where, order = order, limit = limit, offset = offset).objects

proc count*[T: Tmodel](this: Torm, model: T): int =
    result = this.find(model, countOnly = true).count

proc countBy*[T: Tmodel](this: Torm, model: T, where: string, values: seq[string]): int =
    result = this.find(model, where = (clause: where, values: values)).count

proc save*[T: Tmodel](this: Torm, model: T) =
    if model.id == 0:
        this.insert(model) > -1
    else:
        this.update(model)

proc delete*[T: Tmodel](this: Torm, model: T) =
    var statement = "DELETE FROM \"" & $typedesc(model) & "\" WHERE id = ?"
    if model.id != -1:
        this.db.exec(sql statement, @[model.id])


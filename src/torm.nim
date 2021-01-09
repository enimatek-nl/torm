import db_sqlite, json
from strutils import parseInt

type
    Tmodel* = ref object of RootObj
        Tname*: string
        Tfields*: seq[tuple[name: string, kind: string]]
        id*: int64

proc Tinit*[T: Tmodel](this: T, fresh = true): T {.discardable.} =
    this.Tname = $typedesc(this)
    if fresh: this.id = -1
    for col, value in this[].fieldPairs:
        if col != "Tfields" and col != "Tname":
            this.Tfields.add((name: col, kind: $typeof(value)))
    result = this

proc Trow[T: Tmodel](this: T, row: seq[string]): T =
    var json = "{\"Tname\": \"\", \"Tfields\": [], \"id\": " & row[0]
    var i = 1
    for col in this.Tfields:
        if col.name != "Tfields" and col.name != "Tname" and col.name != "id":
            json &= ", \"" & col.name & "\": " & (if col.kind == "string": escapeJson row[i] else: escapeJsonUnquoted row[i])
            i += 1
    result = to(parseJson(json & "}"), T)
    result.Tinit(false)

type
    Torm* = ref object
        db: DbConn

    Torder* = enum
        Asc = " ASC ", Desc = " DESC "

proc columnInfo(this: Torm, column: tuple[name: string, kind: string]): string =
    if column.name == "id":
        result = "INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL"
    else:
        result = case column.kind:
            of "bool":
                "BOOLEAN NOT NULL DEFAULT false"
            of "int8", "int16", "int32", "int64", "int":
                "INTEGER NOT NULL DEFAULT 0"
            else:
                "TEXT"

proc newTorm*[T: Tmodel](dbName: string, models: varargs[T]): Torm =
    let db = open(dbName, "", "", "")
    let orm = Torm(db: db)

    for model in models:
        var list: seq[string] = @[]
        for row in db.fastRows(sql("PRAGMA table_info(" & model.Tname & ");")):
            list.add(row[1])
        if list.len > 0:
            # Lets check if new columns have been added
            for column in model.Tfields:
                if not list.contains(column.name):
                    var statement = "ALTER TABLE \"" & model.Tname & "\" ADD COLUMN " & column.name & " " & orm.columnInfo(column) & ";"
                    db.exec(sql(statement))

        else:
            # Lets make a new table
            var statement = "CREATE TABLE IF NOT EXISTS \"" & model.Tname & "\" ("
            for column in model.Tfields:
                if statement[^1] != '(': statement &= ", "
                statement &= "\"" & column.name & "\" " & orm.columnInfo(column)
            statement &= ");"
            db.exec(sql(statement))

    return orm

proc insert[T: Tmodel](this: Torm, model: T): int64 {.discardable.} =
    var statement = "INSERT INTO \"" & model.Tname & "\" ("
    var late = " VALUES ("
    var list: seq[string] = @[]
    for col, value in model[].fieldPairs:
        if col != "Tfields" and col != "Tname" and col != "id":
            if statement[^1] != '(': statement &= ", "
            statement &= col
            if late[^1] != '(': late &= ", "
            late &= "?"
            list.add($value)
    let prepared = statement & ")" & late & ")"
    model.id = this.db.tryInsertID(sql prepared, list)
    result = model.id

proc update[T: Tmodel](this: Torm, model: T): bool {.discardable.} =
    var statement = "UPDATE \"" & model.Tname & "\" SET "
    var list: seq[string] = @[]
    for col, value in model[].fieldPairs:
        if col != "Tfields" and col != "Tname" and col != "id":
            if statement[^1] != ' ': statement &= ", "
            statement &= col & " = ?"
            list.add($value)
    list.add($model.id)
    statement &= " WHERE id = ?"
    echo statement
    result = this.db.tryExec(sql statement, list)

proc find[T: Tmodel](this: Torm, model: T, where = (clause: "", values: @[""]), order = (by: "id", way: Torder.Asc), limit = 0, offset = 0, countOnly = false): tuple[count: int, objects: seq[T]] =
    var select = "id"
    for col in model.Tfields:
        if col.name != "id": select &= "," & col.name
    if countOnly: select = "COUNT(*) AS total"
    select = "SELECT " & select & " FROM \"" & model.Tname & "\""
    if where.clause != "":
        select &= " WHERE " & where.clause
    select &= " ORDER BY " & order.by & $order.way
    if not countOnly:
        if limit > 0: select &= " LIMIT " & $limit
        if offset > 0: select &= " OFFSET " & $offset

    for x in this.db.fastRows(sql select, where.values):
        if not countOnly:
            result.objects.add T().Tinit().Trow(x)
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
    if model.id == -1:
        this.insert(model) > -1
    else:
        this.update(model)

proc delete*[T: Tmodel](this: Torm, model: T) =
    var statement = "DELETE FROM \"" & model.Tname & "\" WHERE id = ?"
    if model.id != -1:
        this.db.exec(sql statement, @[model.id])

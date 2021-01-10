import ../src/torm

# Use object Tmodel to create your own ref objects
type
    User = ref object of Tmodel
        name: string
        lastname: string
        age: int
        blocked: bool

    Log = ref object of Tmodel
        message: string
        userId: int64

# Create and / or update the tables during the creation of the Torm object
let orm = newTorm("example.db", @[
        User().Tinit,
        Log().Tinit
    ])
# don't forget .Tinit, it's called to construct some internal lookup data for the ORM

# Let's create our first object
let foo = User()
foo.name = "Joe"
foo.lastname = "Unknown"
foo.age = 18

# Simply persist a Tmodel using .save
orm.save foo
echo foo.id # foo now has an id

for i in countup(18, 38):

    # Add some more users
    let user = User()
    user.name = "Joe" & $i
    user.age = i
    orm.save user

    # Give each user a Log
    let log = Log()
    log.message = "message " & $i
    log.userId = user.id
    orm.save log

# See how many Log columns there are available
echo orm.count Log()

# Get 5 users of age above 30
let users = orm.findMany(User(), where = (clause: "age > ?", values: @[$30]), limit = 5)

for user in users:
    # Get associated Log
    let logs = orm.findMany(Log(), where = (clause: "userId = ?", values: @[$user.id]))
    if logs.len > 0:
        echo user.name & " has a message: " & logs[0].message

# If you already know the id use .findOne
let user = orm.findOne(User(), 1)
echo user.name # Our first Joe

# You can alter found objects and save them again to update the database
user.lastname = "Changed"
orm.save user

# You can also use where in countBy and order + offset in findMany eg.
discard orm.findMany(Log(), order = (by: "id", way: Torder.Desc), limit = 5, offset = 1)
echo orm.countBy(User(), "age > ?", @[$20])

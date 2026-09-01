# Databricks notebook source
dbutils.widgets.text("dept", "offices")
dept = dbutils.widgets.get("dept")
print("Child notebook running for dept:", dept)

# COMMAND ----------

data = [
    (1, "Alice", "offices"),
    (2, "Bob", "sales"),
    (3, "Carol", "offices"),
    (4, "Dave", "production"),
    (5, "Erin", "offices"),
]

df = spark.createDataFrame(data, ["emp_id", "name", "dept"])
emp = df.filter(df.dept == dept)
emp.display()

# COMMAND ----------

# Tra ket qua ve notebook cha - bat buoc phai la chuoi
dbutils.notebook.exit(str(emp.count()))

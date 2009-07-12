(* Copyright (c) 2008-2009, Adam Chlipala
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * - Redistributions of source code must retain the above copyright notice,
 *   this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 * - The names of contributors may not be used to endorse or promote products
 *   derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *)

structure MySQL :> MYSQL = struct

open Settings
open Print.PD
open Print

fun p_sql_type t =
    case t of
        Int => "bigint"
      | Float => "double"
      | String => "longtext"
      | Bool => "bool"
      | Time => "timestamp"
      | Blob => "longblob"
      | Channel => "bigint"
      | Client => "int"
      | Nullable t => p_sql_type t

fun p_buffer_type t =
    case t of
        Int => "MYSQL_TYPE_LONGLONG"
      | Float => "MYSQL_TYPE_DOUBLE"
      | String => "MYSQL_TYPE_STRING"
      | Bool => "MYSQL_TYPE_LONG"
      | Time => "MYSQL_TYPE_TIME"
      | Blob => "MYSQL_TYPE_BLOB"
      | Channel => "MYSQL_TYPE_LONGLONG"
      | Client => "MYSQL_TYPE_LONG"
      | Nullable t => p_buffer_type t

fun init {dbstring, prepared = ss, tables, views, sequences} =
    let
        val host = ref NONE
        val user = ref NONE
        val passwd = ref NONE
        val db = ref NONE
        val port = ref NONE
        val unix_socket = ref NONE

        fun stringOf r = case !r of
                             NONE => string "NULL"
                           | SOME s => box [string "\"",
                                            string (String.toString s),
                                            string "\""]
    in
        app (fn s =>
                case String.fields (fn ch => ch = #"=") s of
                    [name, value] =>
                    (case name of
                         "host" =>
                         if size value > 0 andalso String.sub (value, 0) = #"/" then
                             unix_socket := SOME value
                         else
                             host := SOME value
                       | "hostaddr" => host := SOME value
                       | "port" => port := Int.fromString value
                       | "dbname" => db := SOME value
                       | "user" => user := SOME value
                       | "password" => passwd := SOME value
                       | _ => ())
                  | _ => ()) (String.tokens Char.isSpace dbstring);

        box [string "typedef struct {",
             newline,
             box [string "MYSQL *conn;",
                  newline,
                  p_list_sepi (box [])
                              (fn i => fn _ =>
                                          box [string "MYSQL_STMT *p",
                                               string (Int.toString i),
                                               string ";",
                                               newline])
                              ss],
             string "} uw_conn;",
             newline,
             newline,

             if #persistent (currentProtocol ()) then
                 box [string "static void uw_db_prepare(uw_context ctx) {",
                      newline,
                      string "uw_conn *conn = uw_get_db(ctx);",
                      newline,
                      string "MYSQL_STMT *stmt;",
                      newline,
                      newline,

                      p_list_sepi newline (fn i => fn (s, n) =>
                                                      let
                                                          fun uhoh this s args =
                                                              box [p_list_sepi (box [])
                                                                               (fn j => fn () =>
                                                                                           box [string
                                                                                                    "mysql_stmt_close(conn->p",
                                                                                                string (Int.toString j),
                                                                                                string ");",
                                                                                                newline])
                                                                               (List.tabulate (i, fn _ => ())),
                                                                   box (if this then
                                                                            [string
                                                                                 "mysql_stmt_close(conn->p",
                                                                             string (Int.toString i),
                                                                             string ");",
                                                                             newline]
                                                                        else
                                                                            []),
                                                                   string "mysql_close(conn->conn);",
                                                                   newline,
                                                                   string "uw_error(ctx, FATAL, \"",
                                                                   string s,
                                                                   string "\"",
                                                                   p_list_sep (box []) (fn s => box [string ", ",
                                                                                                     string s]) args,
                                                                   string ");",
                                                                   newline]
                                                      in
                                                          box [string "stmt = mysql_stmt_init(conn->conn);",
                                                               newline,
                                                               string "if (stmt == NULL) {",
                                                               newline,
                                                               uhoh false "Out of memory allocating prepared statement" [],
                                                               string "}",
                                                               newline,

                                                               string "if (mysql_stmt_prepare(stmt, \"",
                                                               string (String.toString s),
                                                               string "\", ",
                                                               string (Int.toString (size s)),
                                                               string ")) {",
                                                               newline,
                                                               box [string "char msg[1024];",
                                                                    newline,
                                                                    string "strncpy(msg, mysql_stmt_error(stmt), 1024);",
                                                                    newline,
                                                                    string "msg[1023] = 0;",
                                                                    newline,
                                                                    uhoh true "Error preparing statement: %s" ["msg"]],
                                                               string "}",
                                                               newline,
                                                               string "conn->p",
                                                               string (Int.toString i),
                                                               string " = stmt;",
                                                               newline]
                                                      end)
                                  ss,

                      string "}"]
             else
                 string "static void uw_db_prepare(uw_context ctx) { }",
             newline,
             newline,
             
             string "void uw_db_init(uw_context ctx) {",
             newline,
             string "MYSQL *mysql = mysql_init(NULL);",
             newline,
             string "uw_conn *conn;",
             newline,
             string "if (mysql == NULL) uw_error(ctx, FATAL, ",
             string "\"libmysqlclient can't allocate a connection.\");",
             newline,
             string "if (mysql_real_connect(mysql, ",
             stringOf host,
             string ", ",
             stringOf user,
             string ", ",
             stringOf passwd,
             string ", ",
             stringOf db,
             string ", ",
             case !port of
                 NONE => string "0"
               | SOME n => string (Int.toString n),
             string ", ",
             stringOf unix_socket,
             string ", 0)) {",
             newline,
             box [string "char msg[1024];",
                  newline,
                  string "strncpy(msg, mysql_error(mysql), 1024);",
                  newline,
                  string "msg[1023] = 0;",
                  newline,
                  string "mysql_close(mysql);",
                  newline,
                  string "uw_error(ctx, BOUNDED_RETRY, ",
                  string "\"Connection to MySQL server failed: %s\", msg);"],
             newline,
             string "}",
             newline,
             string "conn = calloc(1, sizeof(conn));",
             newline,
             string "conn->conn = mysql;",
             newline,
             string "uw_set_db(ctx, conn);",
             newline,
             string "uw_db_validate(ctx);",
             newline,
             string "uw_db_prepare(ctx);",
             newline,
             string "}",
             newline,
             newline,

             string "void uw_db_close(uw_context ctx) {",
             newline,
             string "uw_conn *conn = uw_get_db(ctx);",
             newline,
             p_list_sepi (box [])
                         (fn i => fn _ =>
                                     box [string "if (conn->p",
                                          string (Int.toString i),
                                          string ") mysql_stmt_close(conn->p",
                                          string (Int.toString i),
                                          string ");",
                                          newline])
                         ss,
             string "mysql_close(conn->conn);",
             newline,
             string "}",
             newline,
             newline,

             string "int uw_db_begin(uw_context ctx) {",
             newline,
             string "uw_conn *conn = uw_get_db(ctx);",
             newline,
             newline,
             string "return mysql_query(conn->conn, \"SET TRANSACTION ISOLATION LEVEL SERIALIZABLE\")",
             newline,
             string "  || mysql_query(conn->conn, \"BEGIN\");",
             newline,
             string "}",
             newline,
             newline,

             string "int uw_db_commit(uw_context ctx) {",
             newline,
             string "uw_conn *conn = uw_get_db(ctx);",
             newline,
             string "return mysql_commit(conn->conn);",
             newline,
             string "}",
             newline,
             newline,

             string "int uw_db_rollback(uw_context ctx) {",
             newline,
             string "uw_conn *conn = uw_get_db(ctx);",
             newline,
             string "return mysql_rollback(conn->conn);",
             newline,
             string "}",
             newline,
             newline]
    end

fun p_getcol {wontLeakStrings = _, col = i, typ = t} =
    let
        fun getter t =
            case t of
                String => box [string "({",
                               newline,
                               string "uw_Basis_string s = uw_malloc(ctx, length",
                               string (Int.toString i),
                               string " + 1);",
                               newline,
                               string "out[",
                               string (Int.toString i),
                               string "].buffer = s;",
                               newline,
                               string "out[",
                               string (Int.toString i),
                               string "].buffer_length = length",
                               string (Int.toString i),
                               string " + 1;",
                               newline,
                               string "mysql_stmt_fetch_column(stmt, &out[",
                               string (Int.toString i),
                               string "], ",
                               string (Int.toString i),
                               string ", 0);",
                               newline,
                               string "s[length",
                               string (Int.toString i),
                               string "] = 0;",
                               newline,
                               string "s;",
                               newline,
                               string "})"]
              | Blob => box [string "({",
                             newline,
                             string "uw_Basis_blob b = {length",
                             string (Int.toString i),
                             string ", uw_malloc(ctx, length",
                             string (Int.toString i),
                             string ")};",
                             newline,
                             string "out[",
                             string (Int.toString i),
                             string "].buffer = b.data;",
                             newline,
                             string "out[",
                             string (Int.toString i),
                             string "].buffer_length = length",
                             string (Int.toString i),
                             string ";",
                             newline,
                             string "mysql_stmt_fetch_column(stmt, &out[",
                             string (Int.toString i),
                             string "], ",
                             string (Int.toString i),
                             string ", 0);",
                             newline,
                             string "b;",
                             newline,
                             string "})"]
              | Time => box [string "({",
                             string "MYSQL_TIME *mt = buffer",
                             string (Int.toString i),
                             string ";",
                             newline,
                             newline,
                             string "struct tm t = {mt->second, mt->minute, mt->hour, mt->day, mt->month, mt->year, 0, 0, -1};",
                             newline,
                             string "mktime(&tm);",
                             newline,
                             string "})"]
              | _ => box [string "buffer",
                          string (Int.toString i)]
    in
        case t of
            Nullable t => box [string "(is_null",
                               string (Int.toString i),
                               string " ? NULL : ",
                               case t of
                                   String => getter t
                                 | _ => box [string "({",
                                             newline,
                                             string (p_sql_ctype t),
                                             space,
                                             string "*tmp = uw_malloc(ctx, sizeof(",
                                             string (p_sql_ctype t),
                                             string "));",
                                             newline,
                                             string "*tmp = ",
                                             getter t,
                                             string ";",
                                             newline,
                                             string "tmp;",
                                             newline,
                                             string "})"],
                               string ")"]
          | _ => box [string "(is_null",
                      string (Int.toString i),
                      string " ? ",
                      box [string "({",
                           string (p_sql_ctype t),
                           space,
                           string "tmp;",
                           newline,
                           string "uw_error(ctx, FATAL, \"Unexpectedly NULL field #",
                           string (Int.toString i),
                           string "\");",
                           newline,
                           string "tmp;",
                           newline,
                           string "})"],
                      string " : ",
                      getter t,
                      string ")"]
    end

fun queryCommon {loc, query, cols, doCols} =
    box [string "int n, r;",
         newline,
         string "MYSQL_BIND out[",
         string (Int.toString (length cols)),
         string "];",
         newline,
         p_list_sepi (box []) (fn i => fn t =>
                                          let
                                              fun buffers t =
                                                  case t of
                                                      String => box [string "unsigned long length",
                                                                     string (Int.toString i),
                                                                     string ";",
                                                                     newline]
                                                    | Blob => box [string "unsigned long length",
                                                                   string (Int.toString i),
                                                                   string ";",
                                                                   newline]
                                                    | _ => box [string (p_sql_ctype t),
                                                                space,
                                                                string "buffer",
                                                                string (Int.toString i),
                                                                string ";",
                                                                newline]
                                          in
                                              box [string "my_bool is_null",
                                                   string (Int.toString i),
                                                   string ";",
                                                   newline,
                                                   case t of
                                                       Nullable t => buffers t
                                                     | _ => buffers t,
                                                   newline]
                                          end) cols,
         newline,

         string "memset(out, 0, sizeof out);",
         newline,
         p_list_sepi (box []) (fn i => fn t =>
                                          let
                                              fun buffers t =
                                                  case t of
                                                      String => box []
                                                    | Blob => box []
                                                    | _ => box [string "out[",
                                                                string (Int.toString i),
                                                                string "].buffer = &buffer",
                                                                string (Int.toString i),
                                                                string ";",
                                                                newline]
                                          in
                                              box [string "out[",
                                                   string (Int.toString i),
                                                   string "].buffer_type = ",
                                                   string (p_buffer_type t),
                                                   string ";",
                                                   newline,
                                                   string "out[",
                                                   string (Int.toString i),
                                                   string "].is_null = &is_null",
                                                   string (Int.toString i),
                                                   string ";",
                                                   newline,
                                                               
                                                   case t of
                                                       Nullable t => buffers t
                                                     | _ => buffers t,
                                                  newline]
                                          end) cols,
         newline,

         string "if (mysql_stmt_execute(stmt)) uw_error(ctx, FATAL, \"",
         string (ErrorMsg.spanToString loc),
         string ": Error executing query\");",
         newline,
         newline,

         string "if (mysql_stmt_store_result(stmt)) uw_error(ctx, FATAL, \"",
         string (ErrorMsg.spanToString loc),
         string ": Error storing query result\");",
         newline,
         newline,

         string "if (mysql_stmt_bind_result(stmt, out)) uw_error(ctx, FATAL, \"",
         string (ErrorMsg.spanToString loc),
         string ": Error binding query result\");",
         newline,
         newline,

         string "uw_end_region(ctx);",
         newline,
         string "while ((r = mysql_stmt_fetch(stmt)) == 0) {",
         newline,
         doCols p_getcol,
         string "}",
         newline,
         newline,

         string "if (r != MYSQL_NO_DATA) uw_error(ctx, FATAL, \"",
         string (ErrorMsg.spanToString loc),
         string ": query result fetching failed\");",
         newline]    

fun query {loc, cols, doCols} =
    box [string "uw_conn *conn = uw_get_db(ctx);",
         newline,
         string "MYSQL_stmt *stmt = mysql_stmt_init(conn->conn);",
         newline,
         string "if (stmt == NULL) uw_error(ctx, \"",
         string (ErrorMsg.spanToString loc),
         string ": can't allocate temporary prepared statement\");",
         newline,
         string "uw_push_cleanup(ctx, (void (*)(void *))mysql_stmt_close, stmt);",
         newline,
         string "if (mysql_stmt_prepare(stmt, query, strlen(query))) uw_error(ctx, FATAL, \"",
         string (ErrorMsg.spanToString loc),
         string "\");",
         newline,
         newline,

         p_list_sepi (box []) (fn i => fn t =>
                                          let
                                              fun buffers t =
                                                  case t of
                                                      String => box []
                                                    | Blob => box []
                                                    | _ => box [string "out[",
                                                                string (Int.toString i),
                                                                string "].buffer = &buffer",
                                                                string (Int.toString i),
                                                                string ";",
                                                                newline]
                                          in
                                              box [string "in[",
                                                   string (Int.toString i),
                                                   string "].buffer_type = ",
                                                   string (p_buffer_type t),
                                                   string ";",
                                                   newline,
                                                               
                                                   case t of
                                                       Nullable t => box [string "in[",
                                                                          string (Int.toString i),
                                                                          string "].is_null = &is_null",
                                                                          string (Int.toString i),
                                                                          string ";",
                                                                          newline,
                                                                          buffers t]
                                                     | _ => buffers t,
                                                  newline]
                                          end) cols,
         newline,

         queryCommon {loc = loc, cols = cols, doCols = doCols, query = string "query"},

         string "uw_pop_cleanup(ctx);",
         newline]

fun p_ensql t e =
    case t of
        Int => box [string "uw_Basis_attrifyInt(ctx, ", e, string ")"]
      | Float => box [string "uw_Basis_attrifyFloat(ctx, ", e, string ")"]
      | String => e
      | Bool => box [string "(", e, string " ? \"TRUE\" : \"FALSE\")"]
      | Time => box [string "uw_Basis_attrifyTime(ctx, ", e, string ")"]
      | Blob => box [e, string ".data"]
      | Channel => box [string "uw_Basis_attrifyChannel(ctx, ", e, string ")"]
      | Client => box [string "uw_Basis_attrifyClient(ctx, ", e, string ")"]
      | Nullable String => e
      | Nullable t => box [string "(",
                           e,
                           string " == NULL ? NULL : ",
                           p_ensql t (box [string "(*", e, string ")"]),
                           string ")"]

fun queryPrepared {loc, id, query, inputs, cols, doCols} =
    box [string "uw_conn *conn = uw_get_db(ctx);",
         newline,
         string "MYSQL_BIND in[",
         string (Int.toString (length inputs)),
         string "];",
         newline,
         p_list_sepi (box []) (fn i => fn t =>
                                          let
                                              fun buffers t =
                                                  case t of
                                                      String => box [string "unsigned long in_length",
                                                                     string (Int.toString i),
                                                                     string ";",
                                                                     newline]
                                                    | Blob => box [string "unsigned long in_length",
                                                                   string (Int.toString i),
                                                                   string ";",
                                                                   newline]
                                                    | Time => box [string (p_sql_ctype t),
                                                                   space,
                                                                   string "in_buffer",
                                                                   string (Int.toString i),
                                                                   string ";",
                                                                   newline]
                                                    | _ => box []
                                          in
                                              box [case t of
                                                       Nullable t => box [string "my_bool in_is_null",
                                                                          string (Int.toString i),
                                                                          string ";",
                                                                          newline,
                                                                          buffers t]
                                                     | _ => buffers t,
                                                   newline]
                                          end) inputs,
         string "MYSQL_STMT *stmt = conn->p",
         string (Int.toString id),
         string ";",
         newline,
         newline,

         string "memset(in, 0, sizeof in);",
         newline,
         p_list_sepi (box []) (fn i => fn t =>
                                          let
                                              fun buffers t =
                                                  case t of
                                                      String => box [string "in[",
                                                                     string (Int.toString i),
                                                                     string "].buffer = arg",
                                                                     string (Int.toString (i + 1)),
                                                                     string ";",
                                                                     newline,
                                                                     string "in_length",
                                                                     string (Int.toString i),
                                                                     string "= in[",
                                                                     string (Int.toString i),
                                                                     string "].buffer_length = strlen(arg",
                                                                     string (Int.toString (i + 1)),
                                                                     string ");",
                                                                     newline,
                                                                     string "in[",
                                                                     string (Int.toString i),
                                                                     string "].length = &in_length",
                                                                     string (Int.toString i),
                                                                     string ";",
                                                                     newline]
                                                    | Blob => box [string "in[",
                                                                   string (Int.toString i),
                                                                   string "].buffer = arg",
                                                                   string (Int.toString (i + 1)),
                                                                   string ".data;",
                                                                   newline,
                                                                   string "in_length",
                                                                   string (Int.toString i),
                                                                   string "= in[",
                                                                   string (Int.toString i),
                                                                   string "].buffer_length = arg",
                                                                   string (Int.toString (i + 1)),
                                                                   string ".size;",
                                                                   newline,
                                                                   string "in[",
                                                                   string (Int.toString i),
                                                                   string "].length = &in_length",
                                                                   string (Int.toString i),
                                                                   string ";",
                                                                   newline]
                                                    | Time =>
                                                      let
                                                          fun oneField dst src =
                                                              box [string "in_buffer",
                                                                   string (Int.toString i),
                                                                   string ".",
                                                                   string dst,
                                                                   string " = tms.tm_",
                                                                   string src,
                                                                   string ";",
                                                                   newline]
                                                      in
                                                          box [string "({",
                                                               newline,
                                                               string "struct tm tms;",
                                                               newline,
                                                               string "if (localtime_r(&arg",
                                                               string (Int.toString (i + 1)),
                                                               string ", &tm) == NULL) uw_error(\"",
                                                               string (ErrorMsg.spanToString loc),
                                                               string ": error converting to MySQL time\");",
                                                               newline,
                                                               oneField "year" "year",
                                                               oneField "month" "mon",
                                                               oneField "day" "mday",
                                                               oneField "hour" "hour",
                                                               oneField "minute" "min",
                                                               oneField "second" "sec",
                                                               newline,
                                                               string "in[",
                                                               string (Int.toString i),
                                                               string "].buffer = &in_buffer",
                                                               string (Int.toString i),
                                                               string ";",
                                                               newline]
                                                      end
                                                                   
                                                    | _ => box [string "in[",
                                                                string (Int.toString i),
                                                                string "].buffer = &arg",
                                                                string (Int.toString (i + 1)),
                                                                string ";",
                                                                newline]
                                          in
                                              box [string "in[",
                                                   string (Int.toString i),
                                                   string "].buffer_type = ",
                                                   string (p_buffer_type t),
                                                   string ";",
                                                   newline,
                                                               
                                                   case t of
                                                       Nullable t => box [string "in[",
                                                                          string (Int.toString i),
                                                                          string "].is_null = &in_is_null",
                                                                          string (Int.toString i),
                                                                          string ";",
                                                                          newline,
                                                                          string "if (arg",
                                                                          string (Int.toString (i + 1)),
                                                                          string " == NULL) {",
                                                                          newline,
                                                                          box [string "in_is_null",
                                                                               string (Int.toString i),
                                                                               string " = 1;",
                                                                               newline],
                                                                          string "} else {",
                                                                          box [case t of
                                                                                   String => box []
                                                                                 | _ =>
                                                                                   box [string (p_sql_ctype t),
                                                                                        space,
                                                                                        string "arg",
                                                                                        string (Int.toString (i + 1)),
                                                                                        string " = *arg",
                                                                                        string (Int.toString (i + 1)),
                                                                                        string ";",
                                                                                        newline],
                                                                               string "in_is_null",
                                                                               string (Int.toString i),
                                                                               string " = 0;",
                                                                               newline,
                                                                               buffers t,
                                                                               newline]]
                                                                          
                                                     | _ => buffers t,
                                                   newline]
                                          end) inputs,
         newline,

         queryCommon {loc = loc, cols = cols, doCols = doCols, query = box [string "\"",
                                                                            string (String.toString query),
                                                                            string "\""]}]

fun dml _ = box []
fun dmlPrepared _ = box []
fun nextval _ = box []
fun nextvalPrepared _ = box []

val () = addDbms {name = "mysql",
                  header = "mysql/mysql.h",
                  link = "-lmysqlclient",
                  global_init = box [string "void uw_client_init() {",
                                     newline,
                                     box [string "if (mysql_library_init(0, NULL, NULL)) {",
                                          newline,
                                          box [string "fprintf(stderr, \"Could not initialize MySQL library\\n\");",
                                               newline,
                                               string "exit(1);",
                                               newline],
                                          string "}",
                                          newline],
                              string "}",
                                     newline],
                  init = init,
                  p_sql_type = p_sql_type,
                  query = query,
                  queryPrepared = queryPrepared,
                  dml = dml,
                  dmlPrepared = dmlPrepared,
                  nextval = nextval,
                  nextvalPrepared = nextvalPrepared}

end

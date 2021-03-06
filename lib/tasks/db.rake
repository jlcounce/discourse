# we need to run seed_fu every time we run rake db:migrate
task 'db:migrate' => 'environment' do
  SeedFu.seed
end

task 'test:prepare' => 'environment' do
  SeedFu.seed
end

desc 'Rebuild indexes'
task 'db:rebuild_indexes' => 'environment' do
  if Import::backup_tables_count > 0
    raise "Backup from a previous import exists. Drop them before running this job with rake import:remove_backup, or move them to another schema."
  end

  Discourse.enable_readonly_mode

  backup_schema = Jobs::Importer::BACKUP_SCHEMA
  table_names = User.exec_sql("select table_name from information_schema.tables where table_schema = 'public'").map do |row|
    row['table_name']
  end

  begin
    # Move all tables to the backup schema:
    User.exec_sql("DROP SCHEMA IF EXISTS #{backup_schema} CASCADE")
    User.exec_sql("CREATE SCHEMA #{backup_schema}")
    table_names.each do |table_name|
      User.exec_sql("ALTER TABLE public.#{table_name} SET SCHEMA #{backup_schema}")
    end

    # Create a new empty db
    Rake::Task["db:migrate"].invoke

    # Fetch index definitions from the new db
    index_definitions = {}
    table_names.each do |table_name|
      index_definitions[table_name] = User.exec_sql("SELECT indexdef FROM pg_indexes WHERE tablename = '#{table_name}' and schemaname = 'public';").map { |x| x['indexdef'] }
    end

    # Drop the new tables
    table_names.each do |table_name|
      User.exec_sql("DROP TABLE public.#{table_name}")
    end

    # Move the old tables back to the public schema
    table_names.each do |table_name|
      User.exec_sql("ALTER TABLE #{backup_schema}.#{table_name} SET SCHEMA public")
    end

    # Drop their indexes
    index_names = User.exec_sql("SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND tablename IN ('#{table_names.join("', '")}')").map { |x| x['indexname'] }
    index_names.each do |index_name|
      begin
        puts index_name
        User.exec_sql("DROP INDEX public.#{index_name}")
      rescue ActiveRecord::StatementInvalid => e
        # It's this:
        # PG::Error: ERROR:  cannot drop index category_users_pkey because constraint category_users_pkey on table category_users requires it
        # HINT:  You can drop constraint category_users_pkey on table category_users instead.
      end
    end

    # Create the indexes
    table_names.each do |table_name|
      index_definitions[table_name].each do |index_def|
        begin
          User.exec_sql(index_def)
        rescue ActiveRecord::StatementInvalid => e
          # Trying to recreate a primary key
        end
      end
    end
  rescue
    # Can we roll this back?
    raise
  ensure
    Discourse.disable_readonly_mode
  end
end

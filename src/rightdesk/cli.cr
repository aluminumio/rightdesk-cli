require "athena-console"
require "./version"
require "./config"
require "./auth"
require "./client"
require "./support"
require "./commands/session"
require "./commands/deals"
require "./commands/activities"
require "./commands/contacts"
require "./commands/companies"
require "./commands/pipelines"
require "./commands/stages"
require "./commands/products"
require "./commands/customers"
require "./commands/partners"
require "./commands/leads"

module RightDesk
  module CLI
    # Registered command names, used by the ARGV rewriter to validate joins.
    COMMAND_NAMES = %w[
      login logout whoami skills
      deals:list deals:get deals:create deals:update deals:move deals:won deals:lost deals:reopen deals:convert deals:merge
      activities:list activities:get activities:create activities:update activities:delete
      activities:done activities:reopen
      activities:add-blocker activities:remove-blocker
      activities:subtask-add activities:subtask-toggle activities:subtask-remove
      activities:start-timer activities:stop-timer activities:log-time activities:edit-time activities:remove-time
      activities:comment activities:comments activities:history
      contacts:list contacts:get contacts:search contacts:create contacts:update contacts:merge
      companies:list companies:get companies:create companies:update
      customers:list customers:get customers:create customers:update customers:timeline
      partners:list partners:get partners:create partners:update partners:timeline
      pipelines:list pipelines:get pipelines:create pipelines:update pipelines:delete
      stages:list stages:create stages:update stages:reorder stages:delete
      products:list products:get products:create products:update products:activate products:deactivate products:delete
      leads:list leads:get leads:create leads:update leads:delete leads:move leads:qualify leads:disqualify leads:convert
    ]

    def self.run(argv : Array(String)) : Nil
      app = ACON::Application.new("rd", CLI_VERSION)
      app.auto_exit = false
      app.add LoginCommand.new
      app.add LogoutCommand.new
      app.add WhoamiCommand.new
      app.add SkillsCommand.new
      app.add DealsListCommand.new
      app.add DealsGetCommand.new
      app.add DealsCreateCommand.new
      app.add DealsUpdateCommand.new
      app.add DealsMoveCommand.new
      app.add DealsWonCommand.new
      app.add DealsLostCommand.new
      app.add DealsReopenCommand.new
      app.add DealsConvertCommand.new
      app.add DealsMergeCommand.new
      app.add ActivitiesListCommand.new
      app.add ActivitiesGetCommand.new
      app.add ActivitiesCreateCommand.new
      app.add ActivitiesUpdateCommand.new
      app.add ActivitiesDeleteCommand.new
      app.add ActivitiesDoneCommand.new
      app.add ActivitiesReopenCommand.new
      app.add ActivitiesAddBlockerCommand.new
      app.add ActivitiesRemoveBlockerCommand.new
      app.add ActivitiesSubtaskAddCommand.new
      app.add ActivitiesSubtaskToggleCommand.new
      app.add ActivitiesSubtaskRemoveCommand.new
      app.add ActivitiesStartTimerCommand.new
      app.add ActivitiesStopTimerCommand.new
      app.add ActivitiesLogTimeCommand.new
      app.add ActivitiesEditTimeCommand.new
      app.add ActivitiesRemoveTimeCommand.new
      app.add ActivitiesCommentCommand.new
      app.add ActivitiesCommentsCommand.new
      app.add ActivitiesHistoryCommand.new
      app.add ContactsListCommand.new
      app.add ContactsSearchCommand.new
      app.add ContactsGetCommand.new
      app.add ContactsCreateCommand.new
      app.add ContactsUpdateCommand.new
      app.add ContactsMergeCommand.new
      app.add CustomersListCommand.new
      app.add CustomersGetCommand.new
      app.add CustomersCreateCommand.new
      app.add CustomersUpdateCommand.new
      app.add CustomersTimelineCommand.new
      app.add PartnersListCommand.new
      app.add PartnersGetCommand.new
      app.add PartnersCreateCommand.new
      app.add PartnersUpdateCommand.new
      app.add PartnersTimelineCommand.new
      app.add CompaniesListCommand.new
      app.add CompaniesGetCommand.new
      app.add CompaniesCreateCommand.new
      app.add CompaniesUpdateCommand.new
      app.add PipelinesListCommand.new
      app.add PipelinesGetCommand.new
      app.add PipelinesCreateCommand.new
      app.add PipelinesUpdateCommand.new
      app.add PipelinesDeleteCommand.new
      app.add StagesListCommand.new
      app.add StagesCreateCommand.new
      app.add StagesUpdateCommand.new
      app.add StagesReorderCommand.new
      app.add StagesDeleteCommand.new
      app.add ProductsListCommand.new
      app.add ProductsGetCommand.new
      app.add ProductsCreateCommand.new
      app.add ProductsUpdateCommand.new
      app.add ProductsActivateCommand.new
      app.add ProductsDeactivateCommand.new
      app.add ProductsDeleteCommand.new
      app.add LeadsListCommand.new
      app.add LeadsGetCommand.new
      app.add LeadsCreateCommand.new
      app.add LeadsUpdateCommand.new
      app.add LeadsDeleteCommand.new
      app.add LeadsMoveCommand.new
      app.add LeadsQualifyCommand.new
      app.add LeadsDisqualifyCommand.new
      app.add LeadsConvertCommand.new

      status = app.run(ACON::Input::ARGV.new(preprocess(argv)))
      exit(RightDesk.exit_code? || status.value)
    end

    # Pull out global flags (`--host`, `--token`), then rewrite `<noun> <verb>` to
    # the colon form athena understands.
    def self.preprocess(argv : Array(String)) : Array(String)
      join_noun_verb(extract_global_flags(argv))
    end

    # Extract and apply `--host`/`--token` (either `--flag value` or `--flag=value`),
    # returning the remaining tokens. These are framework-global, so we handle them
    # here rather than declaring them on every command.
    def self.extract_global_flags(argv : Array(String)) : Array(String)
      result = [] of String
      i = 0
      while i < argv.size
        arg = argv[i]
        if arg == "--host" || arg == "--token"
          i += 1
          apply_global(arg, argv[i]?)
        elsif arg.starts_with?("--host=")
          apply_global("--host", arg.split("=", 2)[1])
        elsif arg.starts_with?("--token=")
          apply_global("--token", arg.split("=", 2)[1])
        else
          result << arg
        end
        i += 1
      end
      result
    end

    private def self.apply_global(key : String, value : String?)
      return unless value
      case key
      when "--host"  then RightDesk::Config.host_override = value
      when "--token" then RightDesk::Auth.token_override = value
      end
    end

    # Join the leading non-flag tokens with `:` when they form a registered command.
    # `deals get 5` → `deals:get 5`; bare/unknown/colon forms pass through unchanged.
    def self.join_noun_verb(argv : Array(String)) : Array(String)
      lead = [] of String
      argv.each do |t|
        break if t.starts_with?("-")
        lead << t
      end
      return argv if lead.size < 2

      max = Math.min(3, lead.size)
      max.downto(2) do |k|
        candidate = lead[0, k].join(":")
        return [candidate] + argv[k..] if COMMAND_NAMES.includes?(candidate)
      end
      argv
    end
  end
end

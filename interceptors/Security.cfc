﻿/**
 * Copyright since 2016 by Ortus Solutions, Corp
 * www.ortussolutions.com
 * ---
 * This interceptor provides security to an application. It is very flexible and customizable.
 * It bases off on the ability to secure events by creating rules or annotations on your handlers
 * This interceptor will then try to match a rule to the incoming event and the user's credentials on roles and/or permissions.
 */
component accessors="true" extends="coldbox.system.Interceptor" {

	/**
	 * Is the listener initialized
	 */
	property name="initialized" type="boolean";

	/**
	 * The reference to the security validator for this interceptor
	 */
	property name="validator";

	/**
	 * Configure the interception
	 */
	function configure(){
		// default to false
		variables.initialized = false;

		// Rule Source Checks
		if ( !getProperty( "rulesSource" ).len() ) {
			throw(
				message = "The <code>ruleSource</code> property has not been set.",
				type 	= "Security.NoRuleSourceDefined"
			);
		}
		if ( !reFindNoCase( "^(xml|db|model|json)$", getProperty( "rulesSource" ) ) ) {
			throw(
				message = "The rules source you set is invalid: #getProperty( "rulesSource" )#.",
				detail 	= "The valid sources are xml, db, model, or json",
				type 	= "Security.InvalidRuleSource"
			);
		}

		// PreEvent Security
		if ( not propertyExists( "preEventSecurity" ) or not isBoolean( getProperty( "preEventSecurity" ) ) ) {
			setProperty( "preEventSecurity", false );
		}

		// Verify rule configurations
		rulesSourceChecks();

		// Setup the rules to empty
		setProperty( "rules", [] );
	}

	/**
	 * Once the application has loaded, we then proceed to setup the rule engine
	 *
	 * @event
	 * @interceptData
	 * @rc
	 * @prc
	 * @buffer
	 */
	function afterAspectsLoad(
		event,
		interceptData,
		rc,
		prc,
		buffer
	){
		// if no preEvent, then unregister yourself.
		if ( !getProperty( "preEventSecurity" ) ) {
			unregister( "preEvent" );
		}

		// Load Rules
		setProperty(
			"rules",
			getInstance( "RulesLoader@cbSecurity" ).loadRules( getProperties() )
		);

		// Load up the validator
		registerValidator(
			getInstance( getProperty( "validator" ) )
		);

		// We can now rule!
		variables.initialized = true;
	}

	/**
	 * Our firewall kicks in at preProcess
	 *
	 * @event
	 * @interceptData
	 * @rc
	 * @prc
	 * @buffer
	 */
	function preProcess(
		event,
		interceptData,
		rc,
		prc,
		buffer
	){
		// Check if inited already
		if ( NOT variables.initialized ) {
			afterAspectsLoad( arguments.event, arguments.interceptData );
		}

		// Execute Rule processing
		processRules(
			arguments.event,
			arguments.interceptData,
			arguments.event.getCurrentEvent()
		);
	}

	/**
	 * Listen to before any runEvent()'s
	 *
	 * @event
	 * @interceptData
	 * @rc
	 * @prc
	 * @buffer
	 */
	function preEvent(
		event,
		interceptData,
		rc,
		prc,
		buffer
	){
		if ( getProperty( "preEventSecurity" ) ) {
			processRules(
				arguments.event,
				arguments.interceptData,
				arguments.interceptData.processedEvent
			);
		}
	}

	/**
	 * Process security rules. This method is called from an interception point
	 *
	 * @event Event object
	 * @interceptData Interception info
	 * @currentEvent The possible event syntax to check
	 */
	function processRules(
		required event,
		required interceptData,
		required currentEvent
	){
		var rc 	= event.getCollection();
		var ssl = getProperty( "useSSL" );

		// Verify all rules
		for( var thisRule in getProperty( "rules" ) ){
			// Determine Match Target by event or url
			var matchTarget = ( thisRule.match == "url" ? arguments.event.getCurrentRoutedURL() : arguments.currentEvent );

			// Are we in a whitelist?
			if ( isInPattern( matchTarget, thisRule.whitelist ) ) {
				if ( log.canDebug() ) {
					log.debug( "'#matchTarget#' found in whitelist: #thisRule.whitelist#, skipping..." );
				}
				continue;
			}

			// Are we in the secured list?
			if ( isInPattern( matchTarget, thisRule.securelist ) ) {

				// Verify if user is logged in and in a secure state
				if ( !_isUserInValidState( thisRule ) ) {

					// Log if Necessary
					if ( log.canDebug() ) {
						log.debug(
							"User blocked access to target=#matchTarget#. Rule: #thisRule.toString()#"
						);
					}

					// Save secured incoming URL according to type
					if ( arguments.event.isSES() ) {
						rc._securedURL = arguments.event.buildLink( event.getCurrentRoutedURL() );
					} else{
						rc._securedURL = "#cgi.script_name#";
					}

					// Verify query string as well
					if ( cgi.query_string neq "" ) {
						rc._securedURL = rc._securedURL & "?#cgi.query_string#";
					}

					// Route to redirect event
					relocate(
						event 	= thisRule.redirect,
						persist = "_securedURL",
						ssl 	= ( thisRule.useSSL || arguments.event.isSSL() )
					);

					break;
				}
				// end if valid state
				else{
					if ( log.canDebug() ) {
						log.debug(
							"Secure target=#matchTarget# matched and user validated for rule: #thisRule.toString()#."
						);
					}
					break;
				}
			}
			// No match, continue to next rule
			else{
				if ( log.canDebug() ) {
					log.debug( "Incoming '#matchTarget#' did not match this rule: #thisRule.toString()#" );
				}
			}

		} // end rule iterations
	}

	/**
	 * Register a validator object with this interceptor
	 *
	 * @validator The validator object to register
	 */
	function registerValidator( required validator ){
		if ( structKeyExists( arguments.validator, "userValidator" ) ) {
			variables.validator = arguments.validator;
		} else{
			throw(
				message = "Validator object does not have a 'userValidator' method, I can only register objects with this interface method.",
				type 	= "Security.ValidatorMethodException"
			);
		}
	}

	/********************************* PRIVATE ******************************/

	/**
	 * Verifies that the user is in any role using the validator
	 *
	 * @rule The rule to validate
	 */
	private function _isUserInValidState( required struct rule ){
		//  Validate via Validator
		return variables.validator.userValidator( arguments.rule, variables.controller );
	}

	/**
	 * Verifies that the current event is in a given pattern list
	 *
	 * @currentEvent The current event
	 * @patternList The list pattern to test
	 */
	private function isInPattern( required currentEvent, required patternList ){

		//  Loop Over Patterns
		for ( var pattern in arguments.patternList ) {
			//  Using Regex
			if ( getProperty( "useRegex" ) ) {
				if ( reFindNoCase( trim( pattern ), arguments.currentEvent ) ) {
					return true;
				}
			} else if ( findNoCase( trim( pattern ), arguments.currentEvent ) ) {
				return true;
			}
		}

		return false;
	}

	/**
	 * Validate the rules source property
	 */
	private function rulesSourceChecks(){
		switch ( getProperty( "rulesSource" ) ) {
			case "xml":
			case "json": {
				// Check if file property exists
				if ( !getProperty( "rulesFile" ).len() ) {
					throw(
						message = "Please enter a valid rulesFile setting",
						type 	= "Security.RulesFileNotDefined"
					);
				}
				break;
			}

			case "db": {
				if ( !getProperty( "rulesDSN" ).len() ) {
					throw(
						message = "Missing setting for DB source: rulesDSN ",
						type 	= "Security.RuleDSNNotDefined"
					);
				}
				if ( !getProperty( "rulesTable" ).len() ) {
					throw(
						message = "Missing setting for DB source: rulesTable ",
						type 	= "Security.RulesTableNotDefined"
					);
				}
				break;
			}

			case "model": {
				if ( !getProperty( "rulesModel" ).len() ) {
					throw(
						message = "Missing setting for model source: rulesModel ",
						type 	= "Security.RulesModelNotDefined"
					);
				}

				break;
			}
		}
		// end of switch statement
	}

}
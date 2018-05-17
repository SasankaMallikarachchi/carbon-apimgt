

import ballerina/http;
import ballerina/log;
import ballerina/auth;
import ballerina/cache;
import ballerina/config;
import ballerina/runtime;
import ballerina/time;
import ballerina/io;


@Description {value:"Representation of an API gateway listener"}
@Field {value:"config: EndpointConfiguration instance"}
@Field {value:"secureListener: Secure HTTP Listener instance"}
public type APIGatewayListener object {
    public {
        EndpointConfiguration config;
        http:Listener httpListener;
    }

    new () {
        httpListener = new;
    }

    public function init(EndpointConfiguration config);

    @Description {value:"Gets called when the endpoint is being initialize during package init time"}
    @Return {value:"Error occured during initialization"}
    public function initEndpoint() returns (error);

    @Description {value:"Gets called every time a service attaches itself to this endpoint. Also happens at package initialization."}
    @Param {value:"ep: The endpoint to which the service should be registered to"}
    @Param {value:"serviceType: The type of the service to be registered"}
    public function register(typedesc serviceType);

    @Description {value:"Starts the registered service"}
    public function start();

    @Description {value:"Returns the connector that client code uses"}
    @Return {value:"The connector that client code uses"}
    public function getCallerActions() returns (http:Connection);

    @Description {value:"Stops the registered service"}
    public function stop();
};

@Description {value:"Configuration for secure HTTP service endpoint"}
@Field {value:"host: Host of the service"}
@Field {value:"port: Port number of the service"}
@Field {value:"keepAlive: The keepAlive behaviour of the connection for a particular port"}
@Field {value:"transferEncoding: The types of encoding applied to the response"}
@Field {value:"chunking: The chunking behaviour of the response"}
@Field {value:"secureSocket: The SSL configurations for the service endpoint"}
@Field {value:"httpVersion: Highest HTTP version supported"}
@Field {value:"requestLimits: Request validation limits configuration"}
@Field {value:"filters: Filters to be applied to the request before dispatched to the actual resource"}
@Field {value:"authProviders: The array of AuthProviders which are used to authenticate the users"}
public type EndpointConfiguration {
    string host,
    int port =9090,
    http:KeepAlive keepAlive = "AUTO",
    http:ServiceSecureSocket? secureSocket,
    string httpVersion = "1.1",
    http:RequestLimits? requestLimits,
    http:Filter[] filters,
    http:AuthProvider[]? authProviders,
    boolean isSecured,
};


public function APIGatewayListener::init (EndpointConfiguration config) {
    initiateGatewayConfigurations(config);
    addAuthFiltersForAPIGatewayListener(config);
    self.httpListener.init(config);
    initializeBlockConditions();
}

@Description {value:"Add authn and authz filters"}
@Param {value:"config: EndpointConfiguration instance"}
function addAuthFiltersForAPIGatewayListener (EndpointConfiguration config) {
    // add authentication and authorization filters as the first two filters.
    // if there are any other filters specified, those should be added after the authn and authz filters.
    if (config.filters == null) {
        // can add authn and authz filters directly
        config.filters = createAuthFiltersForSecureListener(config);
    } else {
        http:Filter[] newFilters = createAuthFiltersForSecureListener(config);
        // add existing filters next
        int i = 0;
        while (i < lengthof config.filters) {
            newFilters[i + (lengthof newFilters)] = config.filters[i];
            i = i + 1;
        }
        config.filters = newFilters;
    }
}

@Description {value:"Create an array of auth and authz filters"}
@Param {value:"config: EndpointConfiguration instance"}
@Return {value:"Array of Filters comprising of authn and authz Filters"}
function createAuthFiltersForSecureListener (EndpointConfiguration config) returns (http:Filter[]) {
    // parse and create authentication handlers
    http:AuthHandlerRegistry registry;
    match config.authProviders {
        http:AuthProvider[] providers => {
            int i = 1;
            foreach provider in providers {
                if (lengthof provider.id > 0) {
                    registry.add(provider.id, createAuthHandler(provider));
                } else {
                    registry.add(provider.scheme + "-" + i, createAuthHandler(provider));
                }
                i++;
            }
        }
        () => {
            // if no auth providers are specified, add basic authn handler with config based auth provider
            log:printInfo("No Authenticator found");
        }

    }
    http:Filter[] authFilters = [];
    http:AuthnHandlerChain authnHandlerChain = new(registry);
    //http:AuthnFilter authnFilter = new(authnHandlerChain);
    OAuthnHandler oauthnHandler = new;
    OAuthnFilter authnFilter = new(oauthnHandler, authnHandlerChain);

    ThrottleFilter throttleFilter = new();
    SubscriptionFilter subscriptionFilter = new;

    // use the ballerina in built scope(authz) filter
    cache:Cache authzCache = new(expiryTimeMillis = 300000);
    auth:ConfigAuthStoreProvider configAuthStoreProvider = new;
    auth:AuthStoreProvider authStoreProvider = <auth:AuthStoreProvider>configAuthStoreProvider;
    http:HttpAuthzHandler authzHandler = new(authStoreProvider, authzCache);
    http:AuthzFilter authzFilter = new(authzHandler);
    // wraps the ballerina authz filter in new gateway filter
    OAuthzFilter authzFilterWrapper = new(authzFilter);

    authFilters[0] = <http:Filter> authnFilter;
    authFilters[1] = <http:Filter> authzFilterWrapper;
    authFilters[2] = <http:Filter> subscriptionFilter;
    authFilters[3] = <http:Filter> throttleFilter;

    return authFilters;
}

function createAuthHandler (http:AuthProvider authProvider) returns http:HttpAuthnHandler {
    if (authProvider.scheme == AUTHN_SCHEME_BASIC) {
        auth:AuthStoreProvider authStoreProvider;
        if (authProvider.authStoreProvider == AUTH_PROVIDER_CONFIG) {
            auth:ConfigAuthStoreProvider configAuthStoreProvider = new;
            authStoreProvider = <auth:AuthStoreProvider>configAuthStoreProvider;
        } else {
        // other auth providers are unsupported yet
            error e = {message: "Invalid auth provider: " + authProvider.authStoreProvider };
            throw e;
        }
        http:HttpBasicAuthnHandler basicAuthHandler = new(authStoreProvider);
        return <http:HttpAuthnHandler>basicAuthHandler;
    } else if(authProvider.scheme == AUTH_SCHEME_JWT){
        auth:JWTAuthProviderConfig jwtConfig = {};
        jwtConfig.issuer = authProvider.issuer;
        jwtConfig.audience = authProvider.audience;
        jwtConfig.certificateAlias = authProvider.certificateAlias;
        jwtConfig.trustStoreFilePath = authProvider.trustStore.path but {() => ""};
        jwtConfig.trustStorePassword = authProvider.trustStore.password but {() => ""};
        auth:JWTAuthProvider jwtAuthProvider = new (jwtConfig);
        http:HttpJwtAuthnHandler jwtAuthnHandler = new(jwtAuthProvider);
        return <http:HttpAuthnHandler> jwtAuthnHandler;
    }  else {
        // TODO: create other HttpAuthnHandlers
        error e = {message:"Invalid auth scheme: " + authProvider.scheme };
        throw e;
    }
}

function initiateGatewayConfigurations(EndpointConfiguration config) {
    if(!config.isSecured) {
        config.port = getConfigIntValue(LISTENER_CONF_INSTANCE_ID, LISTENER_CONF_HTTP_PORT, 9090);
    }
    config.host = getConfigValue(LISTENER_CONF_INSTANCE_ID, LISTENER_CONF_HOST,"localhost");
    intitateKeyManagerConfigurations();

}

function intitateKeyManagerConfigurations() {
    KeyManagerConf keyManagerConf;
    Credentials credentials;
    keyManagerConf.serverUrl = getConfigValue(KM_CONF_INSTANCE_ID, KM_SERVER_URL, "https://localhost:9443");
    credentials.username = getConfigValue(KM_CONF_INSTANCE_ID, "username", "admin");
    credentials.password = getConfigValue(KM_CONF_INSTANCE_ID, "password", "admin");
    keyManagerConf.credentials = credentials;
    getGatewayConfInstance().setKeyManagerConf(keyManagerConf);
}

function getConfigValue(string instanceId, string property, string defaultValue) returns string {
    return config:getAsString(instanceId + "." + property, default = defaultValue);
}

function getConfigIntValue(string instanceId, string property, int defaultValue) returns int {
    return config:getAsInt(instanceId + "." + property, default = defaultValue);
}

@Description {value:"Gets called every time a service attaches itself to this endpoint. Also happens at package initialization."}
@Param {value:"ep: The endpoint to which the service should be registered to"}
@Param {value:"serviceType: The type of the service to be registered"}
public function APIGatewayListener::register (typedesc serviceType) {
    self.httpListener.register(serviceType);
}

@Description {value:"Gets called when the endpoint is being initialize during package init time"}
@Return {value:"Error occured during initialization"}
public function APIGatewayListener::initEndpoint() returns (error) {
    return self.httpListener.initEndpoint();
}

@Description {value:"Starts the registered service"}
public function APIGatewayListener::start () {
    self.httpListener.start();
}

@Description {value:"Returns the connector that client code uses"}
@Return {value:"The connector that client code uses"}
public function APIGatewayListener::getCallerActions () returns (http:Connection) {
    return self.httpListener.getCallerActions();
}

@Description {value:"Stops the registered service"}
public function APIGatewayListener::stop () {
    self.httpListener.stop();
}

public http:AuthProvider basicAuthProvider = {
    id : "basic",
    scheme:"basic",
    authStoreProvider: "config"
};

public http:AuthProvider jwtAuthProvider = {
    id: "jwt",
    scheme: "jwt",
    issuer: "ballerina",
    audience: "ballerina",
    certificateAlias: "ballerina",
    trustStore: {
        path: "${ballerina.home}/bre/security/ballerinaTruststore.p12",
        password: "ballerina"
    }
};






